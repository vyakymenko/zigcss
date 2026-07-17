class Zigcss < Formula
  desc "Experimental five-language CSS compiler built with Zig"
  homepage "https://github.com/vyakymenko/zigcss"
  # Pin the immutable PRE-009 source checkpoint; publication requires separate authorization.
  url "https://github.com/vyakymenko/zigcss/archive/526002807edc856eb2dc391551ac3d5c1b77da00.tar.gz"
  version "0.5.0-rc.1"
  sha256 "dbab9f777b795742716841354e0bfe30555cc1d54b21f2a446fdc7dc523e26b1"
  license "MIT"

  depends_on "zig@0.15" => :build

  def install
    system Formula["zig@0.15"].opt_bin/"zig", "build", "-Doptimize=ReleaseFast"
    bin.install "zig-out/bin/zigcss"
  end

  test do
    assert_equal "zigcss #{version}\n", shell_output("#{bin}/zigcss --version")
    (testpath/"test.css").write ".test { color: red; }\n"
    assert_equal ".test{color:red}", shell_output("#{bin}/zigcss test.css --minify")
  end
end
