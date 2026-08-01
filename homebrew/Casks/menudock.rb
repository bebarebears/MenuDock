cask "menudock" do
  version "0.1.0"
  sha256 "a6a4e66da32a84a1623723708aad185764119459a62d4bfdbd3e947575b5e294"

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
