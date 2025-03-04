import Foundation
import AVFoundation

public protocol CameraDelegate: AnyObject {
    func didCaptureBuffer(_ sampleBuffer: CMSampleBuffer)
}
public enum PhysicalCameraLocation {
    case backFacing
    case frontFacing
    case frontFacingMirrored
    
    // Documentation: "The front-facing camera would always deliver buffers in AVCaptureVideoOrientationLandscapeLeft and the back-facing camera would always deliver buffers in AVCaptureVideoOrientationLandscapeRight."
    func imageOrientation() -> ImageOrientation {
        switch self {
            case .backFacing: return .landscapeRight
            case .frontFacing: return .landscapeLeft
            case .frontFacingMirrored: return .landscapeLeft
        }
    }
    
    func captureDevicePosition() -> AVCaptureDevice.Position {
        switch self {
            case .backFacing: return .back
            case .frontFacing: return .front
            case .frontFacingMirrored: return .front
        }
    }
    
    func device() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.devices(for:AVMediaType.video)
        for case let device in devices {
            if (device.position == self.captureDevicePosition()) {
                return device
            }
        }
        
        return AVCaptureDevice.default(for: AVMediaType.video)
    }
}

public struct CameraError: Error {
}

let initialBenchmarkFramesToIgnore = 5

public class Camera: NSObject, ImageSource, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public var location:PhysicalCameraLocation {
        didSet {
            // TODO: Swap the camera locations, framebuffers as needed
            
            if let device = location.device() {
                do {
                    let newInput = try AVCaptureDeviceInput(device: device)

                    captureSession.beginConfiguration()

                    captureSession.removeInput(videoInput)

                    if captureSession.canAddInput(newInput) {
                        captureSession.addInput(newInput)
                        videoInput = newInput
                        inputCamera = device
                        updateCameraFrameRate()
                        
                    } else {
                        captureSession.addInput(videoInput)
                    }

                    for connection in videoOutput.connections {
                        if(connection.isVideoMirroringSupported) {
                            connection.isVideoMirrored = (location == .frontFacingMirrored)
                        }
                    }

                    captureSession.commitConfiguration()

                } catch {
                    debugPrint("Cannot switch camera")
                }
            }
        }
    }
    
    public var frameRate: Int = 25 {
        didSet {
            updateCameraFrameRate()
        }
    }
    
    public var isPaused: Bool = false
    
    public var runBenchmark:Bool = false
    public var logFPS:Bool = false
    public var audioEncodingTarget:AudioEncodingTarget? {
        didSet {
            guard let audioEncodingTarget = audioEncodingTarget else {
                return
            }
            do {
                try self.addAudioInputsAndOutputs()
                audioEncodingTarget.activateAudioTrack()
            } catch {
                print("ERROR: Could not connect audio target with error: \(error)")
            }
        }
    }
    
    public let targets = TargetContainer()
    public weak var delegate: CameraDelegate?
    public let captureSession:AVCaptureSession
    public var inputCamera:AVCaptureDevice!
    public var videoInput:AVCaptureDeviceInput!
    public let videoOutput:AVCaptureVideoDataOutput!
    public var microphone:AVCaptureDevice?
    public var audioInput:AVCaptureDeviceInput?
    public var audioOutput:AVCaptureAudioDataOutput?

    var supportsFullYUVRange:Bool = false
    let captureAsYUV:Bool
    let yuvConversionShader:ShaderProgram?
    let frameRenderingSemaphore = DispatchSemaphore(value:1)

    let cameraProcessingQueue = DispatchQueue(label:"com.sunsetlakesoftware.GPUImage.cameraProcessingQueue", qos: .default)
    let audioProcessingQueue = DispatchQueue(label:"com.sunsetlakesoftware.GPUImage.audioProcessingQueue", qos: .default)

    let framesToIgnore = 5
    var numberOfFramesCaptured = 0
    var totalFrameTimeDuringCapture:Double = 0.0
    var framesSinceLastCheck = 0
    var lastCheckTime = CFAbsoluteTimeGetCurrent()
    
    var captureSessionRestartAttempts = 0

    public init(sessionPreset:AVCaptureSession.Preset,
                cameraDevice:AVCaptureDevice? = nil,
                location:PhysicalCameraLocation = .frontFacing,
                frameRate: Int = 30,
                captureAsYUV:Bool = true) throws {
        self.location = location
        self.captureAsYUV = captureAsYUV

        self.captureSession = AVCaptureSession()
        self.captureSession.beginConfiguration()

        if let cameraDevice = cameraDevice {
            self.inputCamera = cameraDevice
        } else {
            if let device = location.device() {
                self.inputCamera = device
            } else {
                self.videoInput = nil
                self.videoOutput = nil
                self.yuvConversionShader = nil
                self.inputCamera = nil
                super.init()
                throw CameraError()
            }
        }
        
        do {
            self.videoInput = try AVCaptureDeviceInput(device:inputCamera)
        } catch {
            self.videoInput = nil
            self.videoOutput = nil
            self.yuvConversionShader = nil
            super.init()
            throw error
        }
        var selectPreset = sessionPreset

        if self.captureSession.canSetSessionPreset(sessionPreset) {
            self.captureSession.sessionPreset = sessionPreset
            if self.captureSession.canAddInput(self.videoInput) {
                self.captureSession.addInput(self.videoInput)
            }
        }else {
            let presets: [AVCaptureSession.Preset] = [
                .hd4K3840x2160,
                .hd1920x1080,
                .hd1280x720,
                .iFrame1280x720,
                .iFrame960x540,
                .vga640x480,
                .high,
                .low
                // 添加其他预设
            ]
            for preset in presets {
                if self.captureSession.canSetSessionPreset(preset) {
                    self.captureSession.sessionPreset = preset
                    if self.captureSession.canAddInput(self.videoInput) {
                        self.captureSession.addInput(self.videoInput)
                        selectPreset = preset
                        break
                    }
                }
            }
        }
        // Add the video frame output
        videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = false

        if captureAsYUV {
            supportsFullYUVRange = false
            let supportedPixelFormats = videoOutput.availableVideoPixelFormatTypes
            for currentPixelFormat in supportedPixelFormats {
                if ((currentPixelFormat as NSNumber).int32Value == Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
                    supportsFullYUVRange = true
                }
            }
            
            if (supportsFullYUVRange) {
                yuvConversionShader = crashOnShaderCompileFailure("Camera"){try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader:YUVConversionFullRangeFragmentShader)}
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:NSNumber(value:Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))]
            } else {
                yuvConversionShader = crashOnShaderCompileFailure("Camera"){try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader:YUVConversionVideoRangeFragmentShader)}
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:NSNumber(value:Int32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))]
            }
        } else {
            yuvConversionShader = nil
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:NSNumber(value:Int32(kCVPixelFormatType_32BGRA))]
        }

        if (captureSession.canAddOutput(videoOutput)) {
            captureSession.addOutput(videoOutput)
        }
        captureSession.sessionPreset = selectPreset
        
        for connection in videoOutput.connections {
            if(connection.isVideoMirroringSupported) {
                connection.isVideoMirrored = (location == .frontFacingMirrored)
            }
        }

        captureSession.commitConfiguration()

        super.init()
        
        self.frameRate = frameRate
        
        videoOutput.setSampleBufferDelegate(self, queue:cameraProcessingQueue)
        
        NotificationCenter.default.addObserver(self, selector: #selector(Camera.captureSessionRuntimeError(note:)), name: NSNotification.Name.AVCaptureSessionRuntimeError, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(Camera.captureSessionDidStartRunning(note:)), name: NSNotification.Name.AVCaptureSessionDidStartRunning, object: nil)
    }
    
    deinit {
        sharedImageProcessingContext.runOperationSynchronously{
            self.stopCapture()
            self.videoOutput?.setSampleBufferDelegate(nil, queue:nil)
            self.audioOutput?.setSampleBufferDelegate(nil, queue:nil)
        }
    }
    
    private func updateCameraFrameRate() {
        guard
            let captureDevice = inputCamera,
            let range = captureDevice.activeFormat.videoSupportedFrameRateRanges.first else { return }
        
        do {
            try captureDevice.lockForConfiguration()
            
            let rate = Int32(max(min(Float64(frameRate), range.maxFrameRate), range.minFrameRate))
            
            captureDevice.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: rate)
            captureDevice.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: rate)
            captureDevice.unlockForConfiguration()
        } catch {
            debugPrint("An Error occurred: \(error.localizedDescription))")
        }
    }
    
    @objc func captureSessionRuntimeError(note: NSNotification) {
        print("ERROR: Capture session runtime error: \(String(describing: note.userInfo))")
        if(self.captureSessionRestartAttempts < 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.startCapture()
            }
            self.captureSessionRestartAttempts += 1
        }
    }
    
    @objc func captureSessionDidStartRunning(note: NSNotification) {
        self.captureSessionRestartAttempts = 0
    }
    
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isPaused else { return }
        
        guard (output != audioOutput) else {
            self.processAudioSampleBuffer(sampleBuffer)
            return
        }

        guard (frameRenderingSemaphore.wait(timeout:DispatchTime.now()) == DispatchTimeoutResult.success) else { return }
    
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let cameraFrame = CMSampleBufferGetImageBuffer(sampleBuffer)!
        let bufferWidth = CVPixelBufferGetWidth(cameraFrame)
        let bufferHeight = CVPixelBufferGetHeight(cameraFrame)
        let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        CVPixelBufferLockBaseAddress(cameraFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
        
        sharedImageProcessingContext.runOperationAsynchronously{
            let cameraFramebuffer:Framebuffer
            let orientation = self.location.imageOrientation()
            
            self.delegate?.didCaptureBuffer(sampleBuffer)
            
            if self.captureAsYUV {
                let luminanceFramebuffer:Framebuffer
                let chrominanceFramebuffer:Framebuffer
                
                if sharedImageProcessingContext.supportsTextureCaches() {
                    var luminanceTextureRef:CVOpenGLESTexture? = nil
                    let _ = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                         sharedImageProcessingContext.coreVideoTextureCache,
                                                                         cameraFrame,
                                                                         nil,
                                                                         GLenum(GL_TEXTURE_2D),
                                                                         GL_LUMINANCE,
                                                                         GLsizei(bufferWidth),
                                                                         GLsizei(bufferHeight),
                                                                         GLenum(GL_LUMINANCE),
                                                                         GLenum(GL_UNSIGNED_BYTE),
                                                                         0,
                                                                         &luminanceTextureRef)
                    
                    let luminanceTexture = CVOpenGLESTextureGetName(luminanceTextureRef!)
                    
                    glActiveTexture(GLenum(GL_TEXTURE4))
                    glBindTexture(GLenum(GL_TEXTURE_2D), luminanceTexture)
                    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
                    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)

                    luminanceFramebuffer = try! Framebuffer(context:sharedImageProcessingContext,
                                                            orientation:orientation,
                                                            size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)),
                                                            textureOnly:true,
                                                            overriddenTexture:luminanceTexture)
                    
                    var chrominanceTextureRef:CVOpenGLESTexture? = nil
                    let _ = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                         sharedImageProcessingContext.coreVideoTextureCache,
                                                                         cameraFrame,
                                                                         nil,
                                                                         GLenum(GL_TEXTURE_2D),
                                                                         GL_LUMINANCE_ALPHA,
                                                                         GLsizei(bufferWidth / 2),
                                                                         GLsizei(bufferHeight / 2),
                                                                         GLenum(GL_LUMINANCE_ALPHA),
                                                                         GLenum(GL_UNSIGNED_BYTE),
                                                                         1,
                                                                         &chrominanceTextureRef)

                    let chrominanceTexture = CVOpenGLESTextureGetName(chrominanceTextureRef!)

                    glActiveTexture(GLenum(GL_TEXTURE5))
                    glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceTexture)
                    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
                    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)

                    chrominanceFramebuffer = try! Framebuffer(context:sharedImageProcessingContext,
                                                              orientation:orientation,
                                                              size:GLSize(width:GLint(bufferWidth / 2), height:GLint(bufferHeight / 2)),
                                                              textureOnly:true,
                                                              overriddenTexture:chrominanceTexture)
                } else {
                    glActiveTexture(GLenum(GL_TEXTURE4))
                    
                    luminanceFramebuffer = sharedImageProcessingContext.framebufferCache
                        .requestFramebufferWithProperties(orientation:orientation,
                                                          size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)),
                                                          textureOnly:true)
                    luminanceFramebuffer.lock()
                    
                    glBindTexture(GLenum(GL_TEXTURE_2D), luminanceFramebuffer.texture)
                    glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE, GLsizei(bufferWidth), GLsizei(bufferHeight), 0, GLenum(GL_LUMINANCE), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(cameraFrame, 0))
                    
                    glActiveTexture(GLenum(GL_TEXTURE5))
                    
                    chrominanceFramebuffer = sharedImageProcessingContext.framebufferCache
                        .requestFramebufferWithProperties(orientation:orientation,
                                                          size:GLSize(width:GLint(bufferWidth / 2), height:GLint(bufferHeight / 2)),
                                                          textureOnly:true)

                    chrominanceFramebuffer.lock()

                    glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceFramebuffer.texture)
                    glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE_ALPHA, GLsizei(bufferWidth / 2), GLsizei(bufferHeight / 2), 0, GLenum(GL_LUMINANCE_ALPHA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(cameraFrame, 1))
                }
                
                cameraFramebuffer = sharedImageProcessingContext.framebufferCache
                    .requestFramebufferWithProperties(orientation:.portrait,
                                                      size:luminanceFramebuffer.sizeForTargetOrientation(.portrait),
                                                      textureOnly:false)
                
                let conversionMatrix:Matrix3x3

                if (self.supportsFullYUVRange) {
                    conversionMatrix = colorConversionMatrix601FullRangeDefault
                } else {
                    conversionMatrix = colorConversionMatrix601Default
                }
                
                convertYUVToRGB(shader:self.yuvConversionShader!,
                                luminanceFramebuffer:luminanceFramebuffer,
                                chrominanceFramebuffer:chrominanceFramebuffer,
                                resultFramebuffer:cameraFramebuffer,
                                colorConversionMatrix:conversionMatrix)
                
            } else {
                cameraFramebuffer = sharedImageProcessingContext.framebufferCache
                    .requestFramebufferWithProperties(orientation:orientation,
                                                      size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)),
                                                      textureOnly:true)
                
                glBindTexture(GLenum(GL_TEXTURE_2D), cameraFramebuffer.texture)
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA, GLsizei(bufferWidth), GLsizei(bufferHeight), 0, GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddress(cameraFrame))
            }
            
            CVPixelBufferUnlockBaseAddress(cameraFrame, CVPixelBufferLockFlags(rawValue:CVOptionFlags(0)))
            
            cameraFramebuffer.timingStyle = .videoFrame(timestamp:Timestamp(currentTime))

            self.updateTargetsWithFramebuffer(cameraFramebuffer)
            
            if self.runBenchmark {
                self.numberOfFramesCaptured += 1
                if (self.numberOfFramesCaptured > initialBenchmarkFramesToIgnore) {
                    let currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime)
                    self.totalFrameTimeDuringCapture += currentFrameTime
                    print("Average frame time : \(1000.0 * self.totalFrameTimeDuringCapture / Double(self.numberOfFramesCaptured - initialBenchmarkFramesToIgnore)) ms")
                    print("Current frame time : \(1000.0 * currentFrameTime) ms")
                }
            }
            
            if self.logFPS {
                if ((CFAbsoluteTimeGetCurrent() - self.lastCheckTime) > 1.0) {
                    self.lastCheckTime = CFAbsoluteTimeGetCurrent()
                    print("FPS: \(self.framesSinceLastCheck)")
                    self.framesSinceLastCheck = 0
                }
                
                self.framesSinceLastCheck += 1
            }

            self.frameRenderingSemaphore.signal()
        }
    }

    public func startCapture() {
        self.numberOfFramesCaptured = 0
        self.totalFrameTimeDuringCapture = 0
        
        if (!captureSession.isRunning) {
            captureSession.startRunning()
        }
    }
    
    public func stopCapture() {
        if (captureSession.isRunning) {
            captureSession.stopRunning()
        }
    }
    
    public func transmitPreviousImage(to target:ImageConsumer, atIndex:UInt) {
        // Not needed for camera inputs
    }
    
    // MARK: -
    // MARK: Audio processing
    

    public func addAudioInputsAndOutputs() throws {
        guard (self.audioOutput == nil) else { return }
        
        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
        }
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            return
        }
        let audioInput = try AVCaptureDeviceInput(device:microphone)
        if captureSession.canAddInput(audioInput) {
           captureSession.addInput(audioInput)
        }
        let audioOutput = AVCaptureAudioDataOutput()
        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        }
        self.microphone = microphone
        self.audioInput = audioInput
        self.audioOutput = audioOutput
        audioOutput.setSampleBufferDelegate(self, queue:audioProcessingQueue)
    }
    
    public func removeAudioInputsAndOutputs() {
        guard (audioOutput != nil) else { return }
        
        captureSession.beginConfiguration()
        captureSession.removeInput(audioInput!)
        captureSession.removeOutput(audioOutput!)
        audioInput = nil
        audioOutput = nil
        microphone = nil
        captureSession.commitConfiguration()
    }
    
    func processAudioSampleBuffer(_ sampleBuffer:CMSampleBuffer) {
        self.audioEncodingTarget?.processAudioBuffer(sampleBuffer, shouldInvalidateSampleWhenDone: false)
    }
}
