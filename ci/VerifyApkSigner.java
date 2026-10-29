import com.android.apksig.ApkVerifier;

import java.io.File;
import java.io.FileInputStream;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.List;

public class VerifyApkSigner {
    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            throw new IllegalArgumentException("Usage: VerifyApkSigner <apk> <expected-certificate>");
        }

        Certificate expected;
        try (FileInputStream input = new FileInputStream(args[1])) {
            expected = CertificateFactory.getInstance("X.509").generateCertificate(input);
        }

        ApkVerifier.Result result = new ApkVerifier.Builder(new File(args[0])).build().verify();
        if (!result.isVerified()) {
            throw new IllegalStateException("APK signature verification failed: " + result.getAllErrors());
        }

        List<X509Certificate> signers = result.getSignerCertificates();
        if (signers.size() != 1 || !expected.equals(signers.get(0))) {
            throw new IllegalStateException("APK signing certificate does not match the release keystore");
        }

        System.out.println("APK signing certificate matches the release keystore.");
    }
}
