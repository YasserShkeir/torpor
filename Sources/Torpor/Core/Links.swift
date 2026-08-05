import Foundation

/// Every outbound URL in one place, so the About tab, the README and any future
/// release notes cannot drift apart.
enum Links {
    static let repo = URL(string: "https://github.com/YasserShkeir/torpor")!
    static let issues = URL(string: "https://github.com/YasserShkeir/torpor/issues/new/choose")!
    static let discussions = URL(string: "https://github.com/YasserShkeir/torpor/discussions")!
    static let star = URL(string: "https://github.com/YasserShkeir/torpor/stargazers")!
    static let releases = URL(string: "https://github.com/YasserShkeir/torpor/releases")!
    static let sponsor = URL(string: "https://github.com/sponsors/YasserShkeir")!

    // The www host, not the apex: the apex answers 308 and a redirect hop inside
    // a notarised, self-updating binary is a hop that can break without warning.
    static let authorSite = URL(string: "https://www.yasser-shkeir.com")!
    static let authorGitHub = URL(string: "https://github.com/YasserShkeir")!
    static let authorLinkedIn = URL(string: "https://www.linkedin.com/in/yasser-shkeir")!

    static let authorName = "Yasser Shkeir"
}
