import SwiftUI

/// Horizontal answers remain separate from the scroll view's vertical reading gesture.
struct LearningSwipeModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let enabled: Bool
    let answer: (Bool) -> Void
    @State private var translation: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var committing = false
    @State private var visible = false

    private var right: Bool { translation < 0 }
    private var tint: Color { right ? .green : .red }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background(tint.opacity(min(abs(translation) / 400, 0.22)), in: RoundedRectangle(cornerRadius: 20))
            .overlay(alignment: .top) {
                if translation != 0 {
                    Label(right ? "Right" : "Wrong", systemImage: right ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.headline).foregroundStyle(tint)
                        .padding(10).background(.regularMaterial, in: Capsule())
                        .padding(.top, 8).allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .offset(x: reduceMotion ? 0 : translation)
            .opacity(reduceMotion && committing ? 0.4 : 1)
            .allowsHitTesting(!committing)
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onChanged { gesture in
                        guard enabled, !committing else { return }
                        let delta = gesture.translation
                        guard abs(delta.width) > abs(delta.height) * 1.5 else {
                            translation = 0
                            return
                        }
                        translation = delta.width
                    }
                    .onEnded { gesture in
                        guard enabled, !committing else { return }
                        let delta = gesture.translation
                        guard abs(delta.width) >= 80,
                              abs(delta.width) > abs(delta.height) * 1.5 else {
                            withAnimation(.easeOut(duration: 0.18)) { translation = 0 }
                            return
                        }
                        let correct = delta.width < 0
                        committing = true
                        withAnimation(.easeIn(duration: reduceMotion ? 0.12 : 0.24), completionCriteria: .removed) {
                            translation = (correct ? -1 : 1) * max(width * 1.2, abs(delta.width))
                        } completion: {
                            guard visible else { return }
                            answer(correct)
                            // Also restore the card if saving failed; a successful answer changes its identity.
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                translation = 0
                                committing = false
                            }
                        }
                    }
            )
            .onAppear { visible = true }
            .onDisappear { visible = false }
    }
}
