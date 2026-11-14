class Duop < Formula
  desc "Dual-pane TUI file manager in pure x86-64 GNU Assembler (zero libc)"
  homepage "https://github.com/ChessPlayerSedoy/duop"
  url "https://github.com/ChessPlayerSedoy/duop/archive/refs/tags/v2.0.0.tar.gz"
  license "MIT"

  depends_on "binutils" => :build
  depends_on "make" => :build

  def install
    system "make", "release"
    bin.install "duop"
    pkgshare.install "scripts/duop-cd.sh"
    (pkgshare/"layouts").install Dir["layouts/*.layout"]
    (pkgshare/"lang").install Dir["lang/*.lang"]
  end

  test do
    assert_match "Duop", shell_output("#{bin}/duop --version")
  end
end
