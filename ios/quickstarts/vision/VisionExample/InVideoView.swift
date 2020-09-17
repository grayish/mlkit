import UIKit
import AVKit
import MLKit

class InVideoController: UIViewController {
  @IBOutlet fileprivate weak var imageView: UIImageView!
  
  private let detectors: [Detector] = [
    .poseFast,
    .poseAccurate,
  ]
    
  private var currentDetector: Detector = .poseAccurate
  
  private let imagePickerController = UIImagePickerController()
  
  private var viewPlayer: AVPlayer!
  private var imageViewPlayer: AVPlayer!
  private var playerLayer: AVPlayerLayer!
  
  private var output: AVPlayerItemVideoOutput!
  private var displayLink: CADisplayLink!
  private var context: CIContext = CIContext(options: [CIContextOption.workingColorSpace : NSNull()]) // 1
//  private var context: CIContext = CIContext(options: nil) // 1

  private var playerItemObserver: NSKeyValueObservation? // 2
  private var assetURL: URL?
  
  /// An overlay view that displays detection annotations.
  private lazy var annotationOverlayView: UIView = {
    precondition(isViewLoaded)
    let annotationOverlayView = UIView(frame: .zero)
    annotationOverlayView.translatesAutoresizingMaskIntoConstraints = false
    annotationOverlayView.clipsToBounds = true
    return annotationOverlayView
  }()
  
  private func removeDetectionAnnotations() {
    for annotationView in annotationOverlayView.subviews {
      annotationView.removeFromSuperview()
    }
  }
  
  private var _poseDetector: PoseDetector? = nil
  private var poseDetector: PoseDetector? {
    get {
      if _poseDetector == nil {
        let options = PoseDetectorOptions()
        options.detectorMode = .singleImage
        options.performanceMode = .accurate
        _poseDetector = PoseDetector.poseDetector(options: options)
      }
      return _poseDetector
    }
    set(newDetector) {
      _poseDetector = newDetector
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setUpAnnotationOverlayView()
    presentPicker()
  }
  
  private func setUpAnnotationOverlayView() {
    imageView.addSubview(annotationOverlayView)
    NSLayoutConstraint.activate([
      annotationOverlayView.topAnchor.constraint(equalTo: imageView.topAnchor),
      annotationOverlayView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
      annotationOverlayView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
      annotationOverlayView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
    ])
  }
  
//  private func playInVideo() {
//    guard let url = assetURL else { return }
//    self.viewPlayer = AVPlayer(url: url)
//    self.playerLayer = AVPlayerLayer(player: self.viewPlayer)    // player를 붙인 AVPlayerLayer 생성
//    self.playerLayer.videoGravity = .resize
//    self.inVideoView.layer.addSublayer(self.playerLayer)
//    self.playerLayer.frame = self.inVideoView.bounds
//    self.viewPlayer.play()
//  }
}

// MARK: - video picker

extension InVideoController : UINavigationControllerDelegate, UIImagePickerControllerDelegate {
  func presentPicker() {
    imagePickerController.sourceType = .photoLibrary
    imagePickerController.delegate = self
    imagePickerController.mediaTypes = ["public.movie"]
    
    present(imagePickerController, animated: true, completion: nil)
  }
  
  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    if let url = info[UIImagePickerController.InfoKey.mediaURL] as? URL {
      print("Selected item: \(url)")
      assetURL = url
      dismiss(animated: true) {
        //        self.playInVideo()
        self.setUpAVPlayer() {
          self.imageViewPlayer.isMuted = true
        }
      }
    }
  }
}

// MARK: - display

extension InVideoController {
  private func setUpAVPlayer(completion: (()->Void)? = nil) {
    guard let url = self.assetURL else { return }
    
    output = AVPlayerItemVideoOutput(outputSettings: [
      (kCVPixelBufferPixelFormatTypeKey as String): kCVPixelFormatType_32BGRA,
    ])
    let item = AVPlayerItem(url: url)
    item.add(output)
    
    playerItemObserver = item.observe(\.status) { [weak self] item, _ in
      guard item.status == .readyToPlay else { return }
      self?.playerItemObserver = nil
      self?.setupDisplayLink()
      self?.imageViewPlayer.play()
      completion?()
    }
    
    self.imageViewPlayer = AVPlayer(playerItem: item)
  }
  
  private func setupDisplayLink() {
    displayLink = CADisplayLink(target: self, selector: #selector(displayLinkUpdated(link:)))
    displayLink.preferredFramesPerSecond = 10
    displayLink.add(to: .main, forMode: RunLoop.Mode.common)
  }
  
  @objc func displayLinkUpdated(link: CADisplayLink) {
    let time = output.itemTime(forHostTime: CACurrentMediaTime())
    guard output.hasNewPixelBuffer(forItemTime: time),
      let pixbuf = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
    
    let ciImage = CIImage.init(cvPixelBuffer: pixbuf)
    guard let cgImg = context.createCGImage(ciImage, from: ciImage.extent) else { return }
    let uiImage = UIImage(cgImage: cgImg, scale: 1.0, orientation: .up)
    
    imageView.image = uiImage
    detectPoseIn(image: imageView.image)
  }
  
  func stop() {
    imageViewPlayer.rate = 0
    displayLink.invalidate()
  }
}

// MARK: - pose detection

extension InVideoController {
    private func transformMatrix() -> CGAffineTransform {
      guard let image = imageView.image else { return CGAffineTransform() }
      let imageViewWidth = imageView.frame.size.width
      let imageViewHeight = imageView.frame.size.height
      let imageWidth = image.size.width
      let imageHeight = image.size.height
  
      let imageViewAspectRatio = imageViewWidth / imageViewHeight
      let imageAspectRatio = imageWidth / imageHeight
      let scale =
        (imageViewAspectRatio > imageAspectRatio)
          ? imageViewHeight / imageHeight : imageViewWidth / imageWidth
  
      // Image view's `contentMode` is `scaleAspectFit`, which scales the image to fit the size of the
      // image view by maintaining the aspect ratio. Multiple by `scale` to get image's original size.
      let scaledImageWidth = imageWidth * scale
      let scaledImageHeight = imageHeight * scale
      let xValue = (imageViewWidth - scaledImageWidth) / CGFloat(2.0)
      let yValue = (imageViewHeight - scaledImageHeight) / CGFloat(2.0)
  
      var transform = CGAffineTransform.identity.translatedBy(x: xValue, y: yValue)
      transform = transform.scaledBy(x: scale, y: scale)
      return transform
    }
  
    private func pointFrom(_ visionPoint: VisionPoint) -> CGPoint {
      return CGPoint(x: visionPoint.x, y: visionPoint.y)
    }
  
  func detectPoseIn(image: UIImage?) {
    guard let image = image else { return }

    // Initialize a VisionImage object with the given UIImage.
    let visionImage = VisionImage(image: image)
    visionImage.orientation = image.imageOrientation

    if let poseDetector = self.poseDetector {
      poseDetector.process(visionImage) { poses, error in
        guard error == nil, let poses = poses, !poses.isEmpty else {
          let errorString = error?.localizedDescription ?? "No results returned."
          print("Pose detection failed with error: \(errorString)")
          return
        }
        self.removeDetectionAnnotations()
        let transform = self.transformMatrix()

        // Pose detected. Currently, only single person detection is supported.
        poses.forEach { pose in
          for (startLandmarkType, endLandmarkTypesArray) in UIUtilities.poseConnections() {
            let startLandmark = pose.landmark(ofType: startLandmarkType)
            for endLandmarkType in endLandmarkTypesArray {
              let endLandmark = pose.landmark(ofType: endLandmarkType)
              let transformedStartLandmarkPoint = self.pointFrom(startLandmark.position).applying(
                transform)
              let transformedEndLandmarkPoint = self.pointFrom(endLandmark.position).applying(
                transform)
              UIUtilities.addLineSegment(
                fromPoint: transformedStartLandmarkPoint,
                toPoint: transformedEndLandmarkPoint,
                inView: self.annotationOverlayView,
                color: UIColor.green,
                width: 3.0
              )
            }
          }
          for landmark in pose.landmarks {
            let transformedPoint = self.pointFrom(landmark.position).applying(transform)
            UIUtilities.addCircle(
              atPoint: transformedPoint,
              to: self.annotationOverlayView,
              color: UIColor.blue,
              radius: 5.0
            )
          }
          print("Pose Detected")
        }
      }
    }
  }
}


// MARK: - rotate image

extension UIImage {
    func rotate(radians: Float) -> UIImage? {
        var newSize = CGRect(origin: CGPoint.zero, size: self.size).applying(CGAffineTransform(rotationAngle: CGFloat(radians))).size
        // Trim off the extremely small float value to prevent core graphics from rounding it up
        newSize.width = floor(newSize.width)
        newSize.height = floor(newSize.height)

        UIGraphicsBeginImageContextWithOptions(newSize, false, self.scale)
        let context = UIGraphicsGetCurrentContext()!

        // Move origin to middle
        context.translateBy(x: newSize.width/2, y: newSize.height/2)
        // Rotate around middle
        context.rotate(by: CGFloat(radians))
        // Draw the image at its center
        self.draw(in: CGRect(x: -self.size.width/2, y: -self.size.height/2, width: self.size.width, height: self.size.height))

        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return newImage
    }
}
