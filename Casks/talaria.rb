cask "talaria" do
  version "1.2"
  sha256 "fdf220dc4c03b6d3a706eefb73d0fa6cfa56099a5b5a47598a944efc4eaaddcc"

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
