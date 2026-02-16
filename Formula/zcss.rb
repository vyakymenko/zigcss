class Zcss < Formula
  desc "The world's fastest CSS compiler - Built with Zig"
  homepage "https://github.com/vyakymenko/zcss"
  url "https://github.com/vyakymenko/zcss/archive/v0.1.0.tar.gz"
  sha256 ""
  license "MIT"
  head "https://github.com/vyakymenko/zcss.git", branch: "development"

  depends_on "zig" => :build

  def install
    system "zig", "build", "-Doptimize=ReleaseFast"
    bin.install "zig-out/bin/zcss"
  end

  test do
    (testpath/"test.css").write ".test { color: red; }"
    system "#{bin}/zcss", "test.css", "-o", "output.css"
    assert_match ".test", File.read("output.css")
  end
end
