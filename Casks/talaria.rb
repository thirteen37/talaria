cask "talaria" do
  version "2.0"
  sha256 "28d1386ede204d3ea16e966f534b826db8c3f0a88fef924068b683835eaa145a"

  url "https://github.com/thirteen37/talaria/releases/download/v#{version}/Talaria-#{version}.dmg"
  name "Talaria"
  desc "Native SwiftUI front-end for Hermes Agent"
  homepage "https://github.com/thirteen37/talaria"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true # Sparkle self-updates; don't let brew fight it
  depends_on macos: ">= :sonoma" # deploymentTarget 14.0

  app "Talaria.app"

  zap trash: [
    "~/Library/Application Support/Talaria",
    "~/Library/Caches/com.talaria.Talaria",
    "~/Library/Preferences/com.talaria.Talaria.plist",
    "~/Library/Saved Application State/com.talaria.Talaria.savedState",
  ]
end
