class Airportx < Formula
  desc "Wi-Fi inspector for macOS without CoreLocation"
  homepage "https://github.com/fjh658/airportx"
  version "0.0.2"

  def self.local_tarball
    Pathname.new(__dir__).join("../dist/airportx-#{version}-universal.tar.gz").realpath.to_s
  end

  url "file://#{Airportx.local_tarball}"
  sha256 "9f14b84283adc4331cb3b5895430e50c3273e8f26fbadf861d8fc5f29c2962b2"
  head "https://github.com/fjh658/airportx.git", branch: "main"

  def install
    bin.install "airportx"
  end

  def caveats
    <<~EOS
      airportx does not perform any privilege escalation (no sudo, no setuid).
      It uses public APIs and best-effort sources that do not require CoreLocation.
      If the system restricts access to certain Wi-Fi metadata, airportx will simply omit those fields; this is expected and not an error.
    EOS
  end

  test do
    system "#{bin}/airportx", "--help"
  end
end