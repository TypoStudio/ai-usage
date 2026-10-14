import Foundation

/// 앱 전용 키체인 항목. `/usr/bin/security` 로 읽고 쓴다 — 앱을 다시 서명해도 허용 창이 뜨지 않고,
/// `security -i` 에 명령을 stdin 으로 넘기고 비밀은 hex 로 적어 ps·따옴표 문제를 피한다.
public enum AppKeychain {
    public static func read(service: String, account: String) async -> Data? {
        let r = await Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"], timeout: 10)
        return r.status == 0 ? r.stdout : nil
    }

    /// 0 이면 성공, 아니면 `security` 의 종료 코드
    public static func write(service: String, account: String, data: Data) async -> Int32 {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let cmd = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \(hex)\n"
        return await Shell.run("/usr/bin/security", ["-i"], input: Data(cmd.utf8), timeout: 15).status
    }
}
