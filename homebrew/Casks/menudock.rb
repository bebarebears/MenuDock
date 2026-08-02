cask "menudock" do
  version "0.3.1"
  sha256 "4a10a7ec5b05213bfcf7db82c662a774ca00c01068e73dfcbb312b7c3944b0bd"

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
