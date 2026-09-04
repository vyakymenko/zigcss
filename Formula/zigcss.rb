class Zigcss < Formula
  desc "Experimental five-language CSS compiler built with Zig"
  homepage "https://github.com/vyakymenko/zigcss"
  # Pin the immutable stable v0.6.0 source commit and its independently verified archive digest.
  url "https://github.com/vyakymenko/zigcss/archive/6786655d66ca65c5a06421c8ed70d84183722dce.tar.gz"
  version "0.6.0"
  sha256 "059b5732816655a55d9c9787168809f5f58c2fff35504ddc0c5d3d0c9de63010"
  license "MIT"

  depends_on "zig@0.15" => :build

  def install
    system formula_opt_bin("zig@0.15")/"zig", "build", "-Doptimize=ReleaseFast"
    bin.install "zig-out/bin/zigcss"
  end

  test do
    assert_equal "zigcss #{version}\n", shell_output("#{bin}/zigcss --version")
    (testpath/"test.css").write ".test { color: red; }\n"
    assert_equal ".test{color:red}", shell_output("#{bin}/zigcss test.css --minify")
  end
end
