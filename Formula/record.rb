# frozen_string_literal: true

# Homebrew formula for the Record macOS CLI.
class Record < Formula
  desc "Native macOS app capture and local transcription CLI"
  homepage "https://github.com/jlave-dev/record"
  url "https://github.com/jlave-dev/record/releases/download/v0.2.0/record-0.2.0-macos-arm64.tar.gz"
  version "0.2.0"
  sha256 "d0273933b24abf6385421f0d3aabea449e9bbffa5aab20ae3754dec37e79fc03"
  license "MIT"

  depends_on arch: :arm64
  depends_on "ffmpeg"
  depends_on macos: :sequoia
  depends_on "whisper-cpp"

  def install
    prefix.install Dir["*"]
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/record --version").strip
    assert_match "record plugin install", shell_output("#{bin}/record --help")
  end
end
