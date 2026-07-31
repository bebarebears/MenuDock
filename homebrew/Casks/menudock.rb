cask "menudock" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/bebarebears/MenuDock/releases/download/v#{version}/MenuDock-#{version}.dmg"
  name "MenuDock"
  desc "Pin apps and folders to the macOS menu bar"
  homepage "https://github.com/bebarebears/MenuDock"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "MenuDock.app"

  zap trash: [
    "~/Library/Application Support/MenuDock",
  ]
end
