class Zigcss < Formula
  desc "Experimental CSS compiler prototype built with Zig"
  homepage "https://github.com/vyakymenko/zigcss"
  # Pin the verified recovery checkpoint until an authorized release publishes a tag.
  url "https://github.com/vyakymenko/zigcss/archive/f498f7d9f08a85a8f031701e1d3198bce667f871.tar.gz"
  version "0.4.0-rc.3"
  sha256 "a1eda39965844c1ccb2429d0e1a38d690c0be5187695c2901375fed59432d127"
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
