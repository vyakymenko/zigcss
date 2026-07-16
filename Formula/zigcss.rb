class Zigcss < Formula
  desc "Experimental CSS compiler prototype built with Zig"
  homepage "https://github.com/vyakymenko/zigcss"
  # Pin the verified recovery checkpoint until an authorized release publishes a tag.
  url "https://github.com/vyakymenko/zigcss/archive/3fada2359ab1fa262b782a33e9ab2a7bab2c46ca.tar.gz"
  version "0.4.0-rc.2"
  sha256 "2fc630a41af5b5fef1d1e4db551604deac048c1b02ff249d5abbb061ebd5c906"
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
