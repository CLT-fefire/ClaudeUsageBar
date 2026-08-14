// swift-tools-version: 6.2
import PackageDescription

// 앱 소스를 **심볼릭 링크로** 컴파일하는 검증 하네스.
// 복사본이 아니라 실제 파일을 그대로 컴파일하므로 앱과 검증 대상이 갈라지지 않는다.
// 본 패키지(../Package.swift)와 분리한 이유: 앱은 @main executable이라
// testTarget에서 import할 수 없다(라이브러리 분리는 별건의 리팩터링).
//
// 실행: cd Verification && swift run verify
let package = Package(
    name: "Verification",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "verify", path: "Sources/verify")
    ]
)
