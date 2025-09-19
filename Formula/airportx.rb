class Airportx < Formula
  desc "Wi-Fi inspector for macOS without CoreLocation"
  homepage "https://github.com/fjh658/airportx"
  version "0.0.1"
  def self.local_tarball
    Pathname.new(__dir__).join("../dist/airportx-0.0.1-universal.tar.gz").realpath.to_s
  end
  url "file://#{Airportx.local_tarball}"
  sha256 "e668e76e0c256071ae0ac5d9903655175e7c23bf9d8439c39aab95be902bccf7"
  head "https://github.com/fjh658/airportx.git", branch: "main"

  def install
    bin.install "airportx"
  end

  def post_install
    airportx_path = opt_bin / "airportx"
    ohai "Elevating #{airportx_path} to root:setuid"
    system "/usr/bin/sudo", "/usr/sbin/chown", "root", airportx_path
    system "/usr/bin/sudo", "/bin/chmod", "4755", airportx_path
  end

  def caveats
    <<~EOS
      airportx relies on system-wide Wi-Fi metadata that usually requires root.
      After installation this formula attempts to run:
        sudo chown root #{opt_bin}/airportx
        sudo chmod 4755 #{opt_bin}/airportx
      You may be prompted for your password. If the commands fail, rerun them
      manually so airportx can read system Wi-Fi metadata without sudo.
    EOS
  end

  test do
    system "#{bin}/airportx", "--help"
  end
end
