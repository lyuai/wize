import SwiftUI
import UIKit

/// 图片预览的窗口级呈现器：盖在阅读区、评论 sheet 之上，带放大/缩小动画。
@MainActor
final class ImagePreviewPresenter {
    static let shared = ImagePreviewPresenter()

    private var window: UIWindow?

    func present(url: URL, sourceFrame: CGRect?) {
        guard window == nil else { return }
        guard let scene = Self.activeWindowScene() else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let root = AnimatedImageViewer(
            url: url,
            sourceFrame: sourceFrame,
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
    }

    func dismiss() {
        guard let window else { return }
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }
}

/// 放大动画显示在屏幕中央；点周边、单击图片、向下轻扫或点 X 都会缩回关闭。
private struct AnimatedImageViewer: View {
    let url: URL
    let sourceFrame: CGRect?
    let onDismiss: () -> Void

    @State private var image: UIImage?
    @State private var failed = false
    @State private var loading = false
    @State private var appeared = false
    @State private var currentFrame: CGRect = .zero
    @State private var targetFrame: CGRect = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(appeared ? 0.62 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .gesture(
                        DragGesture(minimumDistance: 24).onEnded { value in
                            if value.translation.height > 60 { dismiss() }
                        }
                    )

                if let image {
                    ZoomableImage(image: image, onSingleTap: { dismiss() })
                        .frame(width: currentFrame.width, height: currentFrame.height)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(appeared ? 0.35 : 0), radius: 24, y: 10)
                        .position(x: currentFrame.midX, y: currentFrame.midY)
                        .opacity(appeared ? 1 : 0)
                } else if failed {
                    VStack(spacing: 14) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 34, weight: .light))
                        Text("图片加载失败").font(.subheadline)
                        Button("重试") { Task { await load() } }
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
                        .opacity(appeared ? 1 : 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    Spacer()
                }
            }
            .onAppear {
                targetFrame = Self.fittedFrame(in: geometry.size)
                currentFrame = sourceFrame ?? targetFrame.insetBy(dx: targetFrame.width * 0.25, dy: targetFrame.height * 0.25)
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                    appeared = true
                    currentFrame = targetFrame
                }
            }
        }
    }

    private func dismiss() {
        guard appeared else { return }
        let shrinkFrame = sourceFrame ?? targetFrame.insetBy(dx: targetFrame.width * 0.2, dy: targetFrame.height * 0.2)
        withAnimation(.easeInOut(duration: 0.22)) {
            appeared = false
            currentFrame = shrinkFrame
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { onDismiss() }
    }

    private static func fittedFrame(in size: CGSize) -> CGRect {
        let inset: CGFloat = size.width > 700 ? 56 : 24
        let available = CGSize(width: max(size.width - inset * 2, 80), height: max(size.height - inset * 2, 80))
        return CGRect(x: inset, y: (size.height - available.height) / 2 + max((available.height - min(available.height, available.width)) / 2, 0),
                      width: available.width, height: available.height)
    }

    private func load() async {
        failed = false
        if let cached = RemoteImageLoader.shared.cachedImage(for: url) {
            image = cached
            return
        }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let loaded = await RemoteImageLoader.shared.image(for: url)
        if let loaded {
            image = loaded
        } else {
            failed = true
        }
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
@MainActor
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private var pending: [URL: Task<UIImage?, Never>] = [:]

    private init() { cache.countLimit = 80 }

    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let task = pending[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            var request = URLRequest(url: url)
            request.setValue("https://www.zhihu.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return RemoteImageLoader.decode(data)
        }
        pending[url] = task
        let image = await task.value
        pending[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// GIF 解码为可播放的动图；普通图片直接解码。
    nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }

        var frames: [UIImage] = []
        var duration: Double = 0
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.1
            duration += max(delay, 0.03)
            frames.append(UIImage(cgImage: cgImage))
        }
        guard !frames.isEmpty else { return UIImage(data: data) }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}
