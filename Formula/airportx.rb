class Airportx < Formula
  desc "Wi-Fi inspector for macOS without CoreLocation"
  homepage "https://github.com/fjh658/airportx"
  version "0.0.2"
  def self.local_tarball
    Pathname.new(__dir__).join("../dist/airportx-… 0.0.2-universal.tar.gz").realpath.to_s
  end
  url "file://#{Airportx.local_tarball}"
  sha256 "c893fb424648434dae0edcd15f28ba38633fb61a78e5762ecaaf7dd215cbf871"
  head "https://github.com/fjh658/airportx.git", branch: "main"

  def install
    bin.install "airportx"
  end


  def caveats
    <<~EOS
      airportx does not perform any privilege escalation (no sudo, no setuid).
      It uses public APIs and best‑effort sources that do not require CoreLocation.
      If the system restricts access to certain Wi‑Fi metadata, airportx will simply omit those fields; this is expected and not an error.
    EOS
  end

  test do
    system "#{bin}/airportx", "--help"
  end
end
