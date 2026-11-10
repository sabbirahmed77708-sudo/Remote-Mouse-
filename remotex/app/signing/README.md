This keystore gives every RemoteX APK built by CI the same signature, so a new version can be installed over the old one (in-app update).
It is committed on purpose and its password is in the workflow, so it is NOT secret: it only keeps updates installable.
For stronger protection make the repository private or move the keystore into GitHub Actions secrets.
