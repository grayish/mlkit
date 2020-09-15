import UIKit
import AVKit
import MLKit

class InVideoController: UIViewController, UIImagePickerControllerDelegate & UINavigationControllerDelegate {
  private let detectors: [Detector] = [
    .poseFast,
    .poseAccurate,
  ]
  
  @IBOutlet weak var playerView: UIView!
  @IBOutlet weak var inVideoView: UIView!
  
  private var currentDetector: Detector = .poseAccurate
  
  let imagePickerController = UIImagePickerController()
  
  var viewPlayer: AVPlayer!
  var imageViewPlayer: AVPlayer!
  var playerLayer: AVPlayerLayer!
  
  private var output: AVPlayerItemVideoOutput!
  private var displayLink: CADisplayLink!
  private var context: CIContext = CIContext(options: [CIContextOption.workingColorSpace : NSNull()]) // 1
  private var playerItemObserver: NSKeyValueObservation? // 2
  
  
  private lazy var previewOverlayView: UIImageView = {
    precondition(isViewLoaded)
    let previewOverlayView = UIImageView(frame: .zero)
    previewOverlayView.contentMode = UIView.ContentMode.scaleAspectFill
    previewOverlayView.translatesAutoresizingMaskIntoConstraints = false
    return previewOverlayView
  }()
  
  /// An overlay view that displays detection annotations.
  private lazy var annotationOverlayView: UIView = {
    precondition(isViewLoaded)
    let annotationOverlayView = UIView(frame: .zero)
    annotationOverlayView.translatesAutoresizingMaskIntoConstraints = false
    annotationOverlayView.clipsToBounds = true
    return annotationOverlayView
  }()
  
  private var _poseDetector: PoseDetector? = nil
  private var poseDetector: PoseDetector? {
    get {
      var detector: PoseDetector? = nil
      if _poseDetector == nil {
        let options = PoseDetectorOptions()
        options.detectorMode = .stream
        options.performanceMode = .accurate
        _poseDetector = PoseDetector.poseDetector(options: options)
      }
      detector = _poseDetector
      
      return detector
    }
    set(newDetector) {
      _poseDetector = newDetector
      
    }
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    setUpPreviewOverlayView()
    setUpAnnotationOverlayView()
    presentPicker()
  }
  
  func presentPicker() {
    imagePickerController.sourceType = .photoLibrary
    imagePickerController.delegate = self
    imagePickerController.mediaTypes = ["public.movie"]
    
    present(imagePickerController, animated: true, completion: nil)
  }
  
  private func setUpPreviewOverlayView() {
    playerView.addSubview(previewOverlayView)
    NSLayoutConstraint.activate([
      previewOverlayView.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
      previewOverlayView.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),
      previewOverlayView.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
      previewOverlayView.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
    ])
  }
  
  private func setUpAnnotationOverlayView() {
    playerView.addSubview(annotationOverlayView)
    NSLayoutConstraint.activate([
      annotationOverlayView.topAnchor.constraint(equalTo: playerView.topAnchor),
      annotationOverlayView.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
      annotationOverlayView.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
      annotationOverlayView.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
    ])
  }
  
  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    if let url = info[UIImagePickerController.InfoKey.mediaURL] as? URL {
      print("Selected item: \(url)")
      dismiss(animated: true)
      //      playInVideo(url)
      getImageAndPlay(stream: url) {
        self.imageViewPlayer.isMuted = true
      }
      
    }
  }
  
  private func playInVideo(_ url: URL) {
    self.viewPlayer = AVPlayer(url: url)
    self.playerLayer = AVPlayerLayer(player: self.viewPlayer)    // player를 붙인 AVPlayerLayer 생성
    self.playerLayer.videoGravity = .resize
    self.inVideoView.layer.addSublayer(self.playerLayer)
    self.playerLayer.frame = self.inVideoView.bounds
    self.viewPlayer.play()
  }
  
  func getImageAndPlay(stream: URL, completion: (()->Void)? = nil) {
    ////    imageView.layer.isOpaque = true
    //
    let item = AVPlayerItem(url: stream)
    output = AVPlayerItemVideoOutput(outputSettings: nil)
    item.add(output)
    
    playerItemObserver = item.observe(\.status) { [weak self] item, _ in
      guard item.status == .readyToPlay else { return }
      self?.playerItemObserver = nil
      self?.setupDisplayLink()
      self?.imageViewPlayer.play()
      completion?()
    }
    
    imageViewPlayer = AVPlayer(playerItem: item)
  }
  
  private func setupDisplayLink() {
    displayLink = CADisplayLink(target: self, selector: #selector(displayLinkUpdated(link:)))
    displayLink.preferredFramesPerSecond = 30
    displayLink.add(to: .main, forMode: RunLoop.Mode.common)
  }
  
  @objc func displayLinkUpdated(link: CADisplayLink) {
    let time = output.itemTime(forHostTime: CACurrentMediaTime())
    guard output.hasNewPixelBuffer(forItemTime: time),
      let pixbuf = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
    
    let baseImg = CIImage(cvImageBuffer: pixbuf)
    
    //      let blurImg = baseImg.clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: baseImg.extent)
    guard let cgImg = context.createCGImage(baseImg, from: baseImg.extent) else { return }
    let rotatedImage = UIImage(cgImage: cgImg, scale: 1.0, orientation: .right)
    let visionImage = VisionImage(image: rotatedImage)
    let orientation = UIUtilities.imageOrientation(
      fromDevicePosition: .back
    )
    visionImage.orientation = orientation
    
    let imageWidth = CGFloat(CVPixelBufferGetWidth(pixbuf))
    let imageHeight = CGFloat(CVPixelBufferGetHeight(pixbuf))
    
    //    detectPose(in: visionImage, width: imageWidth, height: imageHeight)
    
    previewOverlayView.image = rotatedImage
  }
  
  func stop() {
    imageViewPlayer.rate = 0
    displayLink.invalidate()
  }
  
  
  //  private func transformMatrix() -> CGAffineTransform {
  //    guard let image = imageView.image else { return CGAffineTransform() }
  //    let imageViewWidth = imageView.frame.size.width
  //    let imageViewHeight = imageView.frame.size.height
  //    let imageWidth = image.size.width
  //    let imageHeight = image.size.height
  //
  //    let imageViewAspectRatio = imageViewWidth / imageViewHeight
  //    let imageAspectRatio = imageWidth / imageHeight
  //    let scale =
  //      (imageViewAspectRatio > imageAspectRatio)
  //        ? imageViewHeight / imageHeight : imageViewWidth / imageWidth
  //
  //    // Image view's `contentMode` is `scaleAspectFit`, which scales the image to fit the size of the
  //    // image view by maintaining the aspect ratio. Multiple by `scale` to get image's original size.
  //    let scaledImageWidth = imageWidth * scale
  //    let scaledImageHeight = imageHeight * scale
  //    let xValue = (imageViewWidth - scaledImageWidth) / CGFloat(2.0)
  //    let yValue = (imageViewHeight - scaledImageHeight) / CGFloat(2.0)
  //
  //    var transform = CGAffineTransform.identity.translatedBy(x: xValue, y: yValue)
  //    transform = transform.scaledBy(x: scale, y: scale)
  //    return transform
  //  }
  
  //  private func pointFrom(_ visionPoint: VisionPoint) -> CGPoint {
  //    return CGPoint(x: visionPoint.x, y: visionPoint.y)
  //  }
  
  //  private func detectPose(in image: VisionImage, width: CGFloat, height: CGFloat) {
  //    sessionQueue.async {
  //      if let poseDetector = self.poseDetector {
  //        var poses: [Pose]
  //        do {
  //          poses = try poseDetector.results(in: image)
  //        } catch let error {
  //          print("Failed to detect poses with error: \(error.localizedDescription).")
  //          return
  //        }
  //        DispatchQueue.main.sync {
  //          //                  self.updatePreviewOverlayView()
  //          //                  self.removeDetectionAnnotations()
  //        }
  //        guard !poses.isEmpty else {
  //          print("Pose detector returned no results.")
  //          return
  //        }
  //        let transform = self.transformMatrix()
  //
  //        DispatchQueue.main.sync {
  //          // Pose detected. Currently, only single person detection is supported.
  //          poses.forEach { pose in
  //            for (startLandmarkType, endLandmarkTypesArray) in UIUtilities.poseConnections() {
  //              let startLandmark = pose.landmark(ofType: startLandmarkType)
  //              for endLandmarkType in endLandmarkTypesArray {
  //                let endLandmark = pose.landmark(ofType: endLandmarkType)
  //                let transformedStartLandmarkPoint = self.pointFrom(startLandmark.position).applying(
  //                  transform)
  //                let transformedEndLandmarkPoint = self.pointFrom(endLandmark.position).applying(
  //                  transform)
  //                UIUtilities.addLineSegment(
  //                  fromPoint: transformedStartLandmarkPoint,
  //                  toPoint: transformedEndLandmarkPoint,
  //                  inView: self.annotationOverlayView,
  //                  color: UIColor.green,
  //                  width: 3.0
  //                )
  //              }
  //            }
  //            for landmark in pose.landmarks {
  //              let transformedPoint = self.pointFrom(landmark.position).applying(transform)
  //              UIUtilities.addCircle(
  //                atPoint: transformedPoint,
  //                to: self.annotationOverlayView,
  //                color: UIColor.blue,
  //                radius: 5.0
  //              )
  //            }
  //          }
  //        }
  //      }
  //    }
  //  }
}
