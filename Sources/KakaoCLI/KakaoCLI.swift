import ArgumentParser

@main
struct KakaoCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kakaocli",
        abstract: "KakaoTalk CLI for AI agents",
        // Bump together with the git tag / Homebrew formula on release.
        version: "0.7.0",
        subcommands: [
            AuthCommand.self,
            CacheCommand.self,
            ChatsCommand.self,
            HarvestCommand.self,
            InspectCommand.self,
            LoginCommand.self,
            MessagesCommand.self,
            QueryCommand.self,
            SchemaCommand.self,
            SearchCommand.self,
            SendCommand.self,
            StatusCommand.self,
            SyncCommand.self,
        ]
    )
}
