import SwiftUI

/// 메뉴바(NSStatusItem)에 그려지는 라벨.
///
/// `ClaudeUsageBarApp`의 `MenuBarExtra { } label:` 안에 인라인으로 두지 않고 분리한 이유:
/// `@main` 파일은 검증 하네스(`Verification/`)에 심볼릭 링크할 수 없어(top-level 코드 충돌)
/// 레이아웃을 실측할 수 없다. 별도 뷰로 빼야 하네스가 **실제 앱 코드**를 재고,
/// 아래 HStack이 사라지면 회귀 검사가 실패한다.
struct MenuBarLabel: View {
    let text: String
    let hasOutage: Bool

    var body: some View {
        // ⚠️ HStack 필수. stack 없이 Image+Text를 나란히 두면 TupleView가 되어
        // 암묵 **세로** 스택으로 렌더된다(실측 28×31pt vs HStack 47×16pt).
        // 상태바 높이는 ~22pt라 31pt는 잘린다 — 경보가 가장 필요한 순간에
        // 사용량 수치가 읽히지 않는다. 회귀 측정: `cd Verification && swift run verify`.
        HStack(spacing: 3) {
            if hasOutage {
                // 메뉴바 아이템은 템플릿 렌더링이라 색이 아니라 심볼로 구분해야 한다.
                Image(systemName: "exclamationmark.triangle.fill")
            }
            Text(text)
        }
    }
}
