cask "menudock" do
  version "0.2.0"
  sha256 "3fe699e6571f73e0af5697031c8d2e533613412c5a549a940104cf150fcd33f3"

  url "https://github.com/bebarebears/MenuDock/releases/download/v#{version}/MenuDock-#{version}.dmg"
  name "MenuDock"
  desc "Pin apps, folders, system metrics and clipboard history to the macOS menu bar"
  homepage "https://github.com/bebarebears/MenuDock"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Symbol form, not ">= :sonoma" — the string comparison syntax is deprecated in
  # Homebrew 6 and warns on every `brew info`/`brew install`.
  depends_on macos: :sonoma

  app "MenuDock.app"

  zap trash: [
    "~/Library/Application Support/MenuDock",
  ]
end
