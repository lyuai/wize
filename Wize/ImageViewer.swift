import Photos
import SwiftUI
import UIKit

/// 图片预览的窗口级呈现器：盖在阅读区、评论 sheet 之上，带放大/缩小动画。
@MainActor
final class ImagePreviewPresenter {
    static let shared = ImagePreviewPresenter()

    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?

    func present(url: URL, sourceFrame: CGRect?) {
        guard window == nil else { return }
        guard let scene = Self.activeWindowScene() else { return }
        previousKeyWindow = scene.keyWindow

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        let root = AnimatedImageViewer(
            model: ImagePreviewModel(url: url),
            sourceFrame: sourceFrame,
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        window.rootViewController = controller
        self.window = window
        window.isHidden = false
        window.makeKeyAndVisible()
    }

    func dismiss() {
        guard let window else { return }
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }
}

/// 负责加载与解码，和视图生命周期解耦：window 一创建就开始加载。
@MainActor
final class ImagePreviewModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var failed = false
    @Published private(set) var saving = false
    @Published private(set) var saveNotice: String?

    let url: URL
    private var loading = false

    init(url: URL) {
        self.url = url
        if let cached = RemoteImageLoader.shared.cachedImage(for: url) {
            self.image = cached
        } else {
            Task { await load() }
        }
    }

    func retry() {
        failed = false
        Task { await load() }
    }

    func saveToPhotos() async {
        guard !saving else { return }
        saving = true
        let result = await PhotoImageSaver.save(url: url)
        saving = false
        let message: String
        switch result {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            message = "已存储到照片"
        case .denied:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            message = "没有照片写入权限"
        case .failed:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            message = "图片存储失败"
        }
        withAnimation(.easeOut(duration: 0.18)) { saveNotice = message }
        try? await Task.sleep(for: .seconds(1.8))
        withAnimation(.easeIn(duration: 0.2)) { saveNotice = nil }
    }

    private func load() async {
        guard image == nil, !loading else { return }
        loading = true
        defer { loading = false }

        let loaded = await withTaskGroup(of: UIImage?.self) { group in
            group.addTask { await RemoteImageLoader.shared.image(for: self.url) }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let loaded {
            image = loaded
        } else {
            failed = true
        }
    }
}

/// 放大动画显示在屏幕中央；点周边、单击图片、向下轻扫或点 X 都会缩回关闭。
private struct AnimatedImageViewer: View {
    @ObservedObject var model: ImagePreviewModel
    let sourceFrame: CGRect?
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 0.94
    @State private var dimmed = true

    var body: some View {
        GeometryReader { geometry in
            let horizontalInset: CGFloat = geometry.size.width > 700 ? 56 : 0
            let verticalInset: CGFloat = geometry.size.width > 700 ? 56 : 0
            let available = CGSize(width: max(geometry.size.width - horizontalInset * 2, 80),
                                   height: max(geometry.size.height - verticalInset * 2, 80))
            ZStack {
                Color.black.opacity(dimmed ? 0.62 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .gesture(
                        DragGesture(minimumDistance: 24).onEnded { value in
                            if value.translation.height > 60 { dismiss() }
                        }
                    )

                if let image = model.image {
                    let fitted = Self.fittedSize(for: image.size, in: available)
                    ZoomableImage(
                        image: image,
                        fittedSize: fitted,
                        cornerRadius: horizontalInset > 0 ? 14 : 0,
                        onSingleTap: { dismiss() }
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(scale)
                } else if model.failed {
                    VStack(spacing: 14) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 34, weight: .light))
                        Text("图片加载失败").font(.subheadline)
                        Button("重试") { model.retry() }
                            .buttonStyle(.borderedProminent)
                            .tint(.white.opacity(0.22))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    ProgressView()
                        .tint(.white)
                        .padding(28)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                VStack {
                    HStack(spacing: 10) {
                        Spacer()
                        if model.image != nil {
                            Button {
                                Task { await model.saveToPhotos() }
                            } label: {
                                Group {
                                    if model.saving {
                                        ProgressView().tint(.white).controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.down.to.line")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 34, height: 34)
                                .background(Color.black.opacity(0.55), in: Circle())
                            }
                            .disabled(model.saving)
                            .accessibilityLabel("存储到照片")
                        }
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Color.black.opacity(0.55), in: Circle())
                        }
                        .accessibilityLabel("关闭图片")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    Spacer()
                    if let notice = model.saveNotice {
                        Text(notice)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.75), in: Capsule())
                            .padding(.bottom, 28)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onAppear {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { scale = 1 }
            }
        }
    }

    private func dismiss() {
        guard dimmed else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            scale = 0.9
            dimmed = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { onDismiss() }
    }

    private static func fittedSize(for imageSize: CGSize, in available: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return available }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

}

/// 可缩放的图片容器（UIScrollView 铺满全屏，初始按 fittedSize 居中，放大时铺满整个屏幕区域）。
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let fittedSize: CGSize
    var cornerRadius: CGFloat = 0
    var onSingleTap: () -> Void = {}

    func makeUIView(context: Context) -> CenteringZoomScrollView {
        let scrollView = CenteringZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.clipsToBounds = true

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = cornerRadius
        imageView.layer.cornerCurve = .continuous
        imageView.tag = 91
        scrollView.addSubview(imageView)
        scrollView.fittedSize = fittedSize

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        let dismissSwipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipeDown))
        dismissSwipe.direction = .down
        dismissSwipe.delegate = context.coordinator
        scrollView.addGestureRecognizer(dismissSwipe)

        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: CenteringZoomScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        if let imageView = scrollView.viewWithTag(91) as? UIImageView {
            if imageView.image !== image {
                imageView.image = image
            }
            imageView.layer.cornerRadius = scrollView.zoomScale > 1.01 ? 0 : cornerRadius
        }
        scrollView.fittedSize = fittedSize
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class CenteringZoomScrollView: UIScrollView {
        var fittedSize: CGSize = .zero {
            didSet {
                if oldValue != fittedSize {
                    applyFittedGeometry()
                }
            }
        }
        private var lastBoundsSize: CGSize = .zero

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != lastBoundsSize {
                lastBoundsSize = bounds.size
                applyFittedGeometry()
            } else {
                centerImageView()
            }
        }

        func applyFittedGeometry() {
            guard bounds.width > 0, bounds.height > 0,
                  fittedSize.width > 0, fittedSize.height > 0,
                  let imageView = viewWithTag(91) else { return }
            if zoomScale != 1 {
                setZoomScale(1, animated: false)
            }
            imageView.transform = .identity
            imageView.frame = CGRect(origin: .zero, size: fittedSize)
            contentSize = fittedSize
            centerImageView()
        }

        func centerImageView() {
            guard let imageView = viewWithTag(91) else { return }
            let offsetX = max((bounds.width - contentSize.width) * 0.5, 0)
            let offsetY = max((bounds.height - contentSize.height) * 0.5, 0)
            imageView.center = CGPoint(
                x: contentSize.width * 0.5 + offsetX,
                y: contentSize.height * 0.5 + offsetY
            )
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var scrollView: CenteringZoomScrollView?
        var onSingleTap: () -> Void = {}

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(91)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let zoomScrollView = scrollView as? CenteringZoomScrollView else { return }
            zoomScrollView.centerImageView()
            if let imageView = zoomScrollView.viewWithTag(91) {
                imageView.layer.cornerRadius = zoomScrollView.zoomScale > 1.01 ? 0 : imageView.layer.cornerRadius
            }
        }

        @objc func handleSingleTap() { onSingleTap() }

        @objc func handleSwipeDown() {
            guard let scrollView, scrollView.zoomScale <= 1.01 else { return }
            onSingleTap()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView, let imageView = scrollView.viewWithTag(91) else { return }
            guard scrollView.zoomScale <= 1.01 else {
                scrollView.setZoomScale(1, animated: true)
                return
            }
            let rawPoint = gesture.location(in: imageView)
            let point = CGPoint(
                x: min(max(rawPoint.x, 0), imageView.bounds.width),
                y: min(max(rawPoint.y, 0), imageView.bounds.height)
            )
            let target: CGFloat = 2.5
            let width = scrollView.bounds.width / target
            let height = scrollView.bounds.height / target
            let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
            scrollView.zoom(to: rect, animated: true)
        }
    }
}

/// 图片加载与 GIF 解码（正文与评论共用）。
/// 网络与解码都在后台执行，避免大图/长动图阻塞主线程造成「点了图片卡住」。
actor RemoteImageLoader {
    static let shared = RemoteImageLoader()

    nonisolated(unsafe) private let cache = NSCache<NSURL, UIImage>()
    private var pending: [URL: Task<UIImage?, Never>] = [:]

    private init() { cache.countLimit = 80 }

    nonisolated func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let task = pending[url] { return await task.value }
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            await RemoteImageLoader.download(url)
        }
        pending[url] = task
        let image = await task.value
        pending[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// 保存到照片时需要原始字节（保留 GIF 动图），不能复用解码后的 UIImage。
    func originalData(for url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("https://www.zhihu.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    private static func download(_ url: URL) async -> UIImage? {
        var request = URLRequest(url: url)
        request.setValue("https://www.zhihu.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return decode(data)
    }

    /// 解码时限制像素尺寸与动图帧数，避免高分辨率图片占用过多内存/主线程时间。
    nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let count = CGImageSourceGetCount(source)
        if count <= 1 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2400,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: cgImage)
            }
            return UIImage(data: data)
        }

        var frames: [UIImage] = []
        var duration: Double = 0
        let maxFrames = 48
        let maxPixel = 640
        for index in 0..<min(count, maxFrames) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.1
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) {
                duration += max(delay, 0.03)
                frames.append(UIImage(cgImage: cgImage))
            }
        }
        guard !frames.isEmpty else { return UIImage(data: data) }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}


enum PhotoSaveResult {
    case success
    case denied
    case failed
}

/// 把图片保存到系统照片图库；GIF 以原始文件写入，保留动图。
@MainActor
enum PhotoImageSaver {
    static func save(url: URL) async -> PhotoSaveResult {
        guard let data = await RemoteImageLoader.shared.originalData(for: url) else { return .failed }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }

        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("wize-photo-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: temporary, options: nil)
                } completionHandler: { success, error in
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
                    }
                }
            }
            return .success
        } catch {
            return .failed
        }
    }
}
