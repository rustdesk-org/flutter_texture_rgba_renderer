import Cocoa
import FlutterMacOS

public class TextureRgbaRendererPlugin: NSObject, FlutterPlugin {
    
    private var renderer: Dictionary<Int64, TextRgba> = [:]
    private var texture_registry: FlutterTextureRegistry?
    
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "texture_rgba_renderer", binaryMessenger: registrar.messenger)
    let instance = TextureRgbaRendererPlugin()
    instance.setTextureRegistry(registry: registrar.textures)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }
    
    public func setTextureRegistry(registry: FlutterTextureRegistry) {
        texture_registry = registry
    }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
    case "createTexture":
        let args = call.arguments as! Dictionary<String, Any?>
        let key = args["key"] as! Int64
        if (renderer[key] != nil) {
            result(-1)
        } else {
            let textRgba = TextRgba.new(registry: texture_registry)
            if (textRgba.textureId == -1) {
                // Dart treats -1 as failure and never closes it; do not store.
                result(-1)
            } else {
                renderer[key] = textRgba
                result(textRgba.textureId)
            }
        }
    case "closeTexture":
        let args = call.arguments as! Dictionary<String, Any?>
        let key = args["key"] as! Int64
        if let textRgba = renderer[key] {
            // Stop Rust-side pushes first, then release; keeping closed
            // textures in `renderer` leaked them and made a reused key
            // return -1 forever.
            TextureRgbaRegistry.remove(textRgba)
            if (-1 != textRgba.textureId) {
                texture_registry?.unregisterTexture(textRgba.textureId)
            }
            renderer.removeValue(forKey: key)
            result(true)
        } else {
            result(false)
        }
        
    case "onRgba":
        let args = call.arguments as! Dictionary<String, Any?>
        let key = args["key"] as! Int64
        let data = args["data"] as! FlutterStandardTypedData
        let height = args["height"] as! Int
        let width = args["width"] as! Int
        let stride_align = args["stride_align"] as! Int
        let textureRgba = renderer[key]
        if (textureRgba == nil) {
            result(false)
        } else {
            result(textureRgba!.markFrameAvaliable(data: data.data, width: width, height: height, stride_align: stride_align))
        }
    case "getTexturePtr":
        let args = call.arguments as! Dictionary<String, Any?>
        let key = args["key"] as! Int64
        let textureRgba = renderer[key]
        if (textureRgba == nil) {
            result(0)
        } else {
            let unmanaged = Unmanaged.passUnretained(textureRgba!)
            let intAddr = UInt(bitPattern: unmanaged.toOpaque())
            result(intAddr)
        }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

