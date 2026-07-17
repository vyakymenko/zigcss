class Zigcss < Formula
  desc "Experimental five-language CSS compiler built with Zig"
  homepage "https://github.com/vyakymenko/zigcss"
  # Pin the immutable PRE-009 source checkpoint; publication requires separate authorization.
  url "https://github.com/vyakymenko/zigcss/archive/18deb7c34e5a2d13d57e07459138d925aed5a6e3.tar.gz"
  version "0.5.0-rc.1"
  sha256 "f7dcb180bbe466f4f4269d699c56110889313c228723aedd1aed22b0c00a19b6"
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
