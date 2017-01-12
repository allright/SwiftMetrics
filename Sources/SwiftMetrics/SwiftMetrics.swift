import agentcore
import KituraRequest
import LoggerAPI
import CloudFoundryEnv
import Dispatch
import Foundation
import SwiftyJSON
import KituraNet
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public protocol SMData {
}

public struct CPUData: SMData {
   public let timeOfSample: Int 
   public let percentUsedByApplication: Float 
   public let percentUsedBySystem: Float
}   

public struct MemData: SMData {
   public let timeOfSample: Int
   public let totalRAMOnSystem: Int
   public let totalRAMUsed: Int
   public let totalRAMFree: Int
   public let applicationAddressSpaceSize: Int
   public let applicationPrivateSize: Int
   public let applicationRAMUsed: Int
}

public struct EnvData: SMData {
   public let data: [String:String]
}

public struct InitData: SMData {
   public let data: [String:String]
}

public struct HTTPData: SMData {
	public let timeOfRequest: Int
	public let url: String
	public let duration: Double
	public let statusCode: HTTPStatusCode?
	public let requestMethod: String

	public init(timeOfRequest: Int, url: String, duration: Double, statusCode: HTTPStatusCode?, requestMethod: String) {
        	self.timeOfRequest = timeOfRequest;
        	self.url = url
		self.duration = duration
		self.statusCode = statusCode
		self.requestMethod = requestMethod
    	}
}

fileprivate struct HttpStats {
    fileprivate var count: Double = 0
    fileprivate var duration: Double = 0
    fileprivate var average: Double = 0
}

fileprivate struct MemoryStats {
    fileprivate var count: Float = 0
    fileprivate var sum: Float = 0
    fileprivate var average: Float = 0
}

fileprivate struct CPUStats {
    fileprivate var count: Float = 0
    fileprivate var sum: Float = 0
    fileprivate var average: Float = 0
}

fileprivate struct ThroughputStats {
    fileprivate var duration: Double = 0
    fileprivate var lastCalculateTime: Double = NSDate().timeIntervalSince1970
    fileprivate var requestCount: Double = 0
    fileprivate var throughput: Double = 0
}

fileprivate struct Metrics {
    //holds the metrics we use for updates and used to create the metrics we send to the auto-scaling service
    fileprivate var httpStats: HttpStats = HttpStats()
    fileprivate var memoryStats: MemoryStats = MemoryStats()
    fileprivate var cpuStats: CPUStats = CPUStats()
    fileprivate var throughputStats: ThroughputStats = ThroughputStats()
}

fileprivate struct AverageMetrics {
    //Stores averages of metrics to send to the auto-scaling service
    fileprivate var responseTime: Double = 0
    fileprivate var memory: Float = 0
    fileprivate var cpu: Float = 0
    fileprivate var throughput : Double = 0
}

private var swiftMon: SwiftMonitor?

private func receiveAgentCoreData(cSourceId: UnsafePointer<CChar>, cSize: CUnsignedInt, data: UnsafeMutableRawPointer) -> Void {
   let size = Int(cSize) 
   if size <= 0 {
      return 
   }
   let source = String(cString: cSourceId)
   if source != "api" {
      let message = String(bytesNoCopy: data, length: size, encoding: String.Encoding.utf8, freeWhenDone: false) ?? ""
      if swiftMon != nil {
         swiftMon!.raiseCoreEvent(topic: source, message: message)
      } 
   }
}

open class SwiftMetrics {

    let loaderApi: loaderCoreFunctions
    let SWIFTMETRICS_VERSION = "99.99.99.29991231"
    var running = false
    typealias monitorPushData = @convention(c) (UnsafePointer<CChar>) -> Void
    typealias monitorSendControl = @convention(c) (UnsafePointer<CChar>, CUnsignedInt, UnsafeMutableRawPointer) -> Void
    typealias monitorRegisterListener = @convention(c) (monitorSendControl) -> Void
    var pushData: monitorPushData? 
    var sendControl: monitorSendControl? 
    var registerListener: monitorRegisterListener?
    var asa: AutoScalar? = nil

    public init() throws{
       
        self.loaderApi = loader_entrypoint().pointee
        try self.loadProperties()
        loaderApi.setLogLevels()
        loaderApi.setProperty("agentcore.version", loaderApi.getAgentVersion())
        loaderApi.setProperty("swiftmetrics.version", SWIFTMETRICS_VERSION)
        loaderApi.logMessage(info, "Swift Application Metrics")
    }

    deinit {
        self.stop()
    }

    private func setDefaultLibraryPath() {
       ///use the directory that the swift program lives in
       let programPath = CommandLine.arguments[0]
       let i = programPath.range(of: "/", options: .backwards)
       var defaultLibraryPath = "."
       if i != nil {
         defaultLibraryPath = programPath.substring(to: i!.lowerBound)
       }
       loaderApi.logMessage(fine, "setDefaultLibraryPath(): to \(defaultLibraryPath)")
       self.setPluginSearch(toDirectory: URL(fileURLWithPath: defaultLibraryPath, isDirectory: true))
    }

    private func loadProperties() throws {
       ///look for healthcenter.properties in current directory
       let fm = FileManager.default
       var propertiesPath = ""
       let currentDir = fm.currentDirectoryPath
       var dirContents = try fm.contentsOfDirectory(atPath: currentDir)
       for dir in dirContents {
          if dir.contains("healthcenter.properties") {
             propertiesPath = "\(currentDir)/\(dir)"
          }
       }
       if propertiesPath.isEmpty {
          ///need to go and look for it in the program's Packages directory
          var workingPath = ""
          if currentDir.contains(".build") {
             ///we're below the Packages directory
             workingPath = currentDir
          } else {
             ///we're above the Packages directory
             workingPath = CommandLine.arguments[0]
          }
          
          let i = workingPath.range(of: ".build")
          var packagesPath = ""
          if i == nil {
			 // we could be in bluemix
		     packagesPath="/home/vcap/app"
		  } else {
             packagesPath = workingPath.substring(to: i!.lowerBound)
          }
          packagesPath.append("Packages")
          _ = fm.changeCurrentDirectoryPath(packagesPath)
          ///omr-agentcore has a version number in it, so search for it
          dirContents = try fm.contentsOfDirectory(atPath: fm.currentDirectoryPath)
          for dir in dirContents {
             if dir.contains("omr-agentcore") {
                ///that's where we want to be!
                _ = fm.changeCurrentDirectoryPath(dir)
             }
          }
          propertiesPath = "\(fm.currentDirectoryPath)/properties/healthcenter.properties"
          _ = fm.changeCurrentDirectoryPath(currentDir)
       
       }
       _ = loaderApi.loadPropertiesFile(propertiesPath) 
    }

    public func setPluginSearch(toDirectory: URL) {
        if toDirectory.isFileURL {
           loaderApi.logMessage(debug, "setPluginSearch(): Setting plugin path to \(toDirectory.path)")
           loaderApi.setProperty("com.ibm.diagnostics.healthcenter.plugin.path", toDirectory.path)
        } else {
           loaderApi.logMessage(warning, "setPluginSearch(): toDirectory is not a valid File URL")
        }
    }

    public func stop() {
        if (running) {
            loaderApi.logMessage(fine, "stop(): Shutting down Swift Application Metrics")
            running = false
            loaderApi.stop()
            loaderApi.shutdown()
        } else {
            loaderApi.logMessage(fine, "stop(): Swift Application Metrics has already stopped")
        }
    }
  
    public func start() {
        if (!running) {
            loaderApi.logMessage(fine, "start(): Starting Swift Application Metrics")
            running = true
            let pluginSearchPath = String(cString: loaderApi.getProperty("com.ibm.diagnostics.healthcenter.plugin.path")!)
            if pluginSearchPath == "" {
               self.setDefaultLibraryPath()
            }
            _ = loaderApi.initialize()
            loaderApi.logMessage(debug, "start(): Forcing MQTT Connection on")
            loaderApi.setProperty("com.ibm.diagnostics.healthcenter.mqtt", "on")
            loaderApi.start()
	    do {
                let appEnv = try CloudFoundryEnv.getAppEnv()
	        if (!appEnv.isLocal) {
                    Log.info("[Auto-scaling Agent] Remote connection - starting agent")
                    asa = try AutoScalar()
                } else {
                    Log.info("[Auto-scaling Agent] Local connection - not starting")
                    asa = nil
                }
            } catch {
	        Log.info("[Auto-scaling Agent] Unable to obtain application environment - not starting")
            }
        } else {
            loaderApi.logMessage(fine, "start(): Swift Application Metrics has already started")
        }
        if !initMonitorApi() {
            loaderApi.logMessage(warning, "Failed to initialize monitoring API")
        }
    }

    public func enable(type: String, config: Any? = nil) {
       if config != nil {
          setConfig(type: type, config: config as Any)
       }
    }

    public func disable(type: String) {
       ///Can't disable common plugins
    }

    public func setConfig(type: String, config: Any) {
      ///this seems to be probe-related - might not be needed
    }

    public func emitData<T: SMData>(_ data: T) {
      if swiftMon != nil {
         swiftMon!.raiseEvent(data: data)
      }
      ///add HC-visual events here
    }

    func localConnect() {
       if isMonitorApiValid() {
          loaderApi.logMessage(fine, "localConnect(): Registering receiveAgentCoreData")
          registerListener!(receiveAgentCoreData)
       } else {
          loaderApi.logMessage(warning, "Monitoring API is not initialized")
       }
    }

    private func fileJoin(path: String, fileName: String) -> String {
       loaderApi.logMessage(debug, "fileJoin(): Returning \(path)/\(fileName)")
       return path + "/" + fileName
    }
    
    private func getFunctionFromLibrary(libraryPath: String, functionName: String) -> UnsafeMutableRawPointer? {
       loaderApi.logMessage(debug, "getFunctionFromLibrary(): Looking for function \(functionName) in library \(libraryPath)")
       guard let handle = dlopen(libraryPath, RTLD_LAZY) else {
          let error = String(cString: dlerror())
          loaderApi.logMessage(warning, "Failed to open library \(libraryPath): \(error)") 
          return nil 
       }
       guard let function = dlsym(handle, functionName) else {
          let error = String(cString: dlerror())
          loaderApi.logMessage(warning, "Failed to find symbol \(functionName) in library \(libraryPath): \(error)")
          dlclose(handle)
          return nil 
       }
       dlclose(handle)
       loaderApi.logMessage(debug, "getFunctionFromLibrary(): Function found")
       return function
    }

    private func getMonitorApiFunction(pluginPath: String, functionName: String) -> UnsafeMutableRawPointer? {
#if os(Linux)
       let libname = "libhcapiplugin.so"
#else
       let libname = "libhcapiplugin.dylib"
#endif
       return getFunctionFromLibrary(libraryPath: fileJoin(path: pluginPath, fileName: libname), functionName: functionName)
    } 
   
    private func isMonitorApiValid() -> Bool {
       loaderApi.logMessage(debug, "isMonitorApiValid(): Returning \(pushData != nil) && \(sendControl != nil) && \(registerListener != nil)")
       return (pushData != nil) && (sendControl != nil) && (registerListener != nil)
    }

    private func initMonitorApi() -> Bool {
       let pluginPath = String(cString: loaderApi.getProperty("com.ibm.diagnostics.healthcenter.plugin.path")!)

       guard let iPushData = getMonitorApiFunction(pluginPath: pluginPath, functionName: "pushData") else {
          loaderApi.logMessage(debug, "initMonitorApi(): Unable to locate pushData. Returning.")
          return false
       }
       pushData = unsafeBitCast(iPushData, to: monitorPushData.self)

       guard let iSendControl = getMonitorApiFunction(pluginPath: pluginPath, functionName: "sendControl") else {
          loaderApi.logMessage(debug, "initMonitorApi(): Unable to locate sendControl. Returning.")
          return false
       }
       sendControl = unsafeBitCast(iSendControl, to: monitorSendControl.self)

       guard let iRegisterListener = getMonitorApiFunction(pluginPath: pluginPath, functionName: "registerListener") else {
          loaderApi.logMessage(debug, "initMonitorApi(): Unable to locate registerListener. Returning.")
          return false
       }
       registerListener = unsafeBitCast(iRegisterListener, to: monitorRegisterListener.self)

       return true
    }

    public func monitor() -> SwiftMonitor {
       if swiftMon == nil {
          swiftMon = SwiftMonitor(swiftMet: self)
       }
       return swiftMon!
    }
}

public class AutoScalar {
    
    var reportInterval: Int = 30
    // the number of s to wait between report thread runs
    
    var availableMonitorInterval: Int = 5
    // the number of s to wait before checking if a monitor is available
     
    var configRefreshInterval: Int = 60
    // the number of s to wait between refresh thread runs
    
    var isAgentEnabled: Bool = true
    // can be turned off from the auto-scaling service in the refresh thread
    
    var enabledMetrics: [String] = []
    // list of metrics to collect (CPU, Memory, HTTP etc. Can be altered by the auto-scaling service in the refresh thread.
    
    let autoScalingRegex = "Auto(.*)Scaling"
    // used to find the AutoScaling service from the Cloud Foundry Application Environment
    
    fileprivate var metrics: Metrics = Metrics() //initialises to defaults above

    var agentUsername = ""
    var agentPassword = ""
    var appID = ""
    var host = ""
    var auth = ""
    var authorization = ""
    var serviceID = ""
    var appName = ""
    var instanceIndex = 0
    var instanceId = ""

    public init(metricsToEnable: [String]) throws{
        enabledMetrics = metricsToEnable
        if !self.initCredentials() {
            return
        }
        self.notifyStatus()
        self.refreshConfig()
        
        DispatchQueue.global(qos: .background).async {
            self.snoozeSetMonitors()
	}
        DispatchQueue.global(qos: .background).async {
            self.snoozeStartReport()
        }
        DispatchQueue.global(qos: .background).async {
            self.snoozeRefreshConfig()
        }
    }

    private func initCredentials() ->  Bool {
        do {
            let appEnv = try CloudFoundryEnv.getAppEnv() 
            
            guard let autoScalingService =  appEnv.getServiceCreds(spec: autoScalingRegex) else {
                Log.info("[Auto-Scaling Agent] Please bind auto-scaling service!")
                return false
            }

            guard let aU = autoScalingService["agentUsername"] else {
                Log.info("[Auto-Scaling Agent] sendMetrics:serviceEnv.agentUsername is not found or empty")
                return false
            }
            agentUsername = aU as! String
            guard let ap = autoScalingService["agentPassword"] else {
                Log.info("[Auto-Scaling Agent] sendMetrics:serviceEnv.agentPassword is not found or empty")
                return false
            }
            agentPassword = ap as! String
            guard let aI = autoScalingService["app_id"] else {
                Log.info("[Auto-Scaling Agent] sendMetrics:serviceEnv.app_id is not found or empty")
                return false
            }

            appID = aI as! String
       
            guard let hostTemp = autoScalingService["url"] else {
                Log.info("[Auto-Scaling Agent] sendMetrics:serviceEnv.url is not found or empty")
                return false
            }

            host = hostTemp as! String
            
            guard let serviceIDTemp = autoScalingService["service_id"] else {
                Log.info("[Auto-Scaling Agent] sendMetrics:serviceEnv.url is not found or empty")
                return false
            }
       
            serviceID = serviceIDTemp as! String

            appName = appEnv.getApp()!.name
     
            instanceIndex = appEnv.getApp()!.instanceIndex
            
            instanceId = appEnv.getApp()!.instanceId 
       
            auth = "\(agentUsername):\(agentPassword)"
            Log.info("[Auto-scaling Agent] Authorisation: \(auth)")
            authorization = Data(auth.utf8).base64EncodedString()
        } catch {
            Log.info("[Auto-Scaling Agent] CloudFoundryEnv.getAppEnv() threw exception")
            return false
        }
        
        return true
    }

    private func snoozeSetMonitors() {
        sleep(UInt32(reportInterval))
	if swiftMon == nil {
          DispatchQueue.global(qos: .background).async {
            self.snoozeSetMonitors()
          }
        } else {
          self.setMonitors()
        }
    }
    
    private func snoozeStartReport() {
        sleep(UInt32(reportInterval))
        self.startReport()
        DispatchQueue.global(qos: .background).async {
            self.snoozeStartReport()
        }
    }


    private func snoozeRefreshConfig() {
        sleep(UInt32(configRefreshInterval))
        self.refreshConfig()
        DispatchQueue.global(qos: .background).async {
            self.snoozeRefreshConfig()
        }
    }



    public convenience init() throws {
        try self.init(metricsToEnable: ["CPU", "Memory", "Throughput"])
    }

    private func setMonitors() {
        swiftMon!.on({(mem: MemData) -> () in
            self.metrics.memoryStats.count += 1
            self.metrics.memoryStats.sum += Float(mem.totalRAMUsed)
        })
        swiftMon!.on({(cpu: CPUData) -> () in
            self.metrics.cpuStats.count += 1
            self.metrics.cpuStats.sum += cpu.percentUsedByApplication * 100;
        })
        swiftMon!.on({(http: HTTPData) -> () in
            self.metrics.httpStats.count += 1
            self.metrics.httpStats.duration += http.duration;
            self.metrics.throughputStats.requestCount += 1;
        })
    }

    private func startReport() {
        if (!isAgentEnabled) {
            Log.info("[Auto-Scaling Agent] Agent is disabled by server")
            return
        }
         
        let metricsToSend = calculateAverageMetrics()
        _ = constructSendObject(metricsToSend: metricsToSend)
        sendMetrics(asOBJ : constructSendObject(metricsToSend: metricsToSend))

    }

    private func calculateAverageMetrics() ->  AverageMetrics {
        metrics.httpStats.average = (metrics.httpStats.duration > 0 && metrics.httpStats.count > 0) ? (metrics.httpStats.duration / metrics.httpStats.count) : 0.0
        metrics.httpStats.count = 0;
        metrics.httpStats.duration = 0;

        metrics.memoryStats.average = (metrics.memoryStats.sum > 0 && metrics.memoryStats.count > 0) ? (metrics.memoryStats.sum / metrics.memoryStats.count) : metrics.memoryStats.average;
        metrics.memoryStats.count = 0;
        metrics.memoryStats.sum = 0;

        metrics.cpuStats.average = (metrics.cpuStats.sum > 0 && metrics.cpuStats.count > 0) ? (metrics.cpuStats.sum / metrics.cpuStats.count) : metrics.cpuStats.average;
        metrics.cpuStats.count = 0;
        metrics.cpuStats.sum = 0;

        if (metrics.throughputStats.requestCount > 0) {
            let currentTime = NSDate().timeIntervalSince1970
            let duration = currentTime - metrics.throughputStats.lastCalculateTime
            metrics.throughputStats.throughput = metrics.throughputStats.requestCount / (duration / 1000)
            metrics.throughputStats.lastCalculateTime = currentTime
            metrics.throughputStats.duration = duration
        } else {
            metrics.throughputStats.throughput = 0
            metrics.throughputStats.duration = 0
        }
        metrics.throughputStats.requestCount = 0

        return AverageMetrics(responseTime: metrics.httpStats.average,
                    memory: metrics.memoryStats.average,
                    cpu: metrics.cpuStats.average,
                    throughput: metrics.throughputStats.throughput
        )
    }

    private func constructSendObject(metricsToSend: AverageMetrics) -> [String:Any] {
        let timestamp = NSDate().timeIntervalSince1970
        var metricsArray: [[String:Any]] = []
        
        for metric in enabledMetrics {
            switch (metric) {
                case "CPU":
		    var metricDict = [String:Any]()
                    metricDict["category"] = "swift"
                    metricDict["group"] = "ProcessCpuLoad"
                    metricDict["name"] = "ProcessCpuLoad"
                    metricDict["value"] = Double(metricsToSend.cpu) * 100.0
                    metricDict["unit"] = "%%"
                    metricDict["desc"] = ""
                    metricsArray.append(metricDict)
              case "Memory":
		    var metricDict = [String:Any]()
                    metricDict["category"] = "swift"
                    metricDict["group"] = "memory"
                    metricDict["name"] = "memory"
                    metricDict["value"] = Double(metricsToSend.memory)
                    metricDict["unit"] = "Bytes"
                    metricDict["desc"] = ""
                    metricsArray.append(metricDict)
              case "Throughput":
		    var metricDict = [String:Any]()
                    metricDict["category"] = "swift"
                    metricDict["group"] = "Web"
                    metricDict["name"] = "throughput"
                    metricDict["value"] = Double(metricsToSend.throughput)
                    metricDict["unit"] = ""
                    metricDict["desc"] = ""
                    metricsArray.append(metricDict)
              default:
                    break
            }
        }

        var dict = [String:Any]()
        dict["appId"] = appID
        dict["appName"] = appName
        dict["appType"] = "swift"
        dict["serviceId"] = serviceID
        dict["instanceIndex"] = instanceIndex
        dict["instanceId"] = instanceId
        dict["timestamp"] = timestamp
        dict["metrics"] = metricsArray

        return dict
    }

    private func sendMetrics(asOBJ : [String:Any]) { 
        let sendMetricsPath = "\(host):443/services/agent/report"
        Log.info("[Auto-scaling Agent] Attempting to send metrics to \(sendMetricsPath)")

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: asOBJ, options: .prettyPrinted)
            let decoded = try JSONSerialization.jsonObject(with: jsonData, options: [])
            if let dictFromJSON = decoded as? [String:Any] {
                KituraRequest.request(.post,
                            sendMetricsPath,
                            parameters: dictFromJSON,
                            encoding: JSONEncoding.default,
                            headers: ["Content-Type":"application/json", "Authorization":"Basic \(authorization)"]
                        ).response {
                            request, response, data, error in
                            Log.info("[Auto-scaling Agent] sendMetrics:Request: \(request!)")
                            Log.info("[Auto-scaling Agent] sendMetrics:Response: \(response!)")
                            Log.info("[Auto-scaling Agent] sendMetrics:Data: \(data!)")
                            Log.info("[Auto-scaling Agent] sendMetrics:Error: \(error)")}
            }
        } catch {
            Log.info("[Auto-Scaling Agent] \(error.localizedDescription)")
        }
    }

    private func notifyStatus() {
        let notifyStatusPath = "\(host):443/services/agent/status/\(appID)"
        Log.info("[Auto-scaling Agent] Attempting notifyStatus request to \(notifyStatusPath)")
        KituraRequest.request(.put,
                notifyStatusPath,
                headers: ["Authorization":"Basic \(authorization)"]
                ).response {
            request, response, data, error in
                Log.info("[Auto-scaling Agent] notifyStatus:Request: \(request!)")
                Log.info("[Auto-scaling Agent] notifyStatus:Response: \(response!)")
                Log.info("[Auto-scaling Agent] notifyStatus:Data: \(data)")
                Log.info("[Auto-scaling Agent] notifyStatus:Error: \(error)")
        }
        
    }


    // Read the config from the autoscaling service to see if any changes have been made    
    private func refreshConfig() {
        let refreshConfigPath = "\(host):443/v1/agent/config/\(serviceID)/\(appID)?appType=swift" //change to swift when supported
        Log.info("[Auto-scaling Agent] Attempting requestConfig request to \(refreshConfigPath)")
        KituraRequest.request(.get,
                refreshConfigPath,
                headers: ["Content-Type":"application/json", "Authorization":"Basic \(authorization)"]
                ).response {
            request, response, data, error in
                Log.info("[Auto-scaling Agent] requestConfig:Request: \(request!)")
                Log.info("[Auto-scaling Agent] requestConfig:Response: \(response!)")
                Log.info("[Auto-scaling Agent] requestConfig:Data: \(data!)")
                Log.info("[Auto-scaling Agent] requestConfig:Error: \(error)")

                Log.info("[Auto-scaling Agent] requestConfig:Body: \(String(data: data!, encoding: .utf8))")
                self.updateConfiguration(response: data!)
        }
    }

    // Update local config from autoscaling service
    private func updateConfiguration(response: Data) {

            let jsonData = JSON(data: response)
            if (jsonData == nil) {
                isAgentEnabled = false
            }
            if (jsonData["metricsConfig"]["agent"] == nil) {
                isAgentEnabled = false
            }            
            enabledMetrics=jsonData["metricsConfig"]["agent"].arrayValue.map({$0.stringValue})
            reportInterval=jsonData["reportInterval"].intValue
      
    }
        
}
