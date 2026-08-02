cask "menudock" do
  version "0.3.0"
  sha256 "b1b6d558153c4ac9dfd53663ee3db368322ecefa6a605a75993537f5488926ed"

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
