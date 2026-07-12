class Zigcss < Formula
  desc "Experimental CSS compiler prototype built with Zig"
  homepage "https://github.com/vyakymenko/zigcss"
  url "https://github.com/vyakymenko/zigcss/archive/v0.4.0-rc.1.tar.gz"
  version "0.4.0-rc.1"
  sha256 ""
  license "MIT"
  head "https://github.com/vyakymenko/zigcss.git", branch: "development"

  depends_on "zig" => :build

  def install
    system "zig", "build", "-Doptimize=ReleaseFast"
    bin.install "zig-out/bin/zigcss"
  end

  test do
    (testpath/"test.css").write ".test { color: red; }"
    system "#{bin}/zigcss", "test.css", "-o", "output.css"
    assert_match ".test", File.read("output.css")
  end
end
