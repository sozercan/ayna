cask "ayna" do
  version "1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/sozercan/ayna/releases/download/v#{version}/ayna-v#{version}.dmg"
  name "Ayna"
  desc "Native macOS ChatGPT client"
  homepage "https://github.com/sozercan/ayna"

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Ayna.app"

  zap trash: [
    "~/Library/Application Support/Ayna",
    "~/Library/Caches/com.sertacozercan.ayna",
    "~/Library/Preferences/com.sertacozercan.ayna.plist",
    "~/Library/Saved Application State/com.sertacozercan.ayna.savedState",
  ]
end
