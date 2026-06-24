cask "talaria" do
  version "1.3"
  sha256 "da7edca9358a844f6a977f2cca5674ba9f7a81c245101f484bc6c0b4274a3dda"

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
