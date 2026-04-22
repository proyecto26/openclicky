cask "clicky-ai" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/proyecto26/clicky-ai-plugin/releases/download/v#{version}/Clicky-#{version}-arm64.dmg"
  name "Clicky"
  desc "Friendly, screen-aware Claude Code companion for macOS"
  homepage "https://github.com/proyecto26/clicky-ai-plugin"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Clicky.app"

  zap trash: [
    "~/Library/Application Support/Clicky",
    "~/Library/Application Support/clicky-ai",
    "~/Library/Preferences/com.proyecto26.clicky.plist",
    "~/Library/Caches/com.proyecto26.clicky",
    "~/Library/Logs/com.proyecto26.clicky",
  ]
end
