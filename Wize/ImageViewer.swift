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
        window.frame = scene.coordinateSpace.bounds
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

    private let url: URL
    private var loading = false

    init(url: URL) {
        self.url = url
        Task { await load() }
    }

    func retry() {
        failed = false
        Task { await load() }
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
            let inset: CGFloat = geometry.size.width > 700 ? 56 : 24
            let available = CGSize(width: max(geometry.size.width - inset * 2, 80),
                                   height: max(geometry.size.height - inset * 2, 80))
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
                    ZoomableImage(image: image, onSingleTap: { dismiss() })
                        .frame(width: fitted.width, height: fitted.height)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
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
                    HStack {
                        Spacer()
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

/// 可缩放的图片容器（UIScrollView 的缩放语义比手势组合更稳定）。
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var onSingleTap: () -> Void = {}

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.tag = 91
        scrollView.addSubview(imageView)

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

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        if let imageView = scrollView.viewWithTag(91) as? UIImageView, imageView.image !== image {
            imageView.image = image
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var scrollView: UIScrollView?
        var onSingleTap: () -> Void = {}

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(91)
        }

        @objc func handleSingleTap() { onSingleTap() }
        @objc func handleSwipeDown() { onSingleTap() }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            guard scrollView.zoomScale <= 1.01 else {
                scrollView.setZoomScale(1, animated: true)
                return
            }
            let point = gesture.location(in: scrollView.viewWithTag(91))
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

    private let cache = NSCache<NSURL, UIImage>()
    private var pending: [URL: Task<UIImage?, Never>] = [:]

    private init() { cache.countLimit = 60 }

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
