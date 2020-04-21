Attribute VB_Name = "mdTlsCrypto"
'=========================================================================
'
' Elliptic-curve cryptography thunks based on the following sources
'
'  1. https://github.com/esxgx/easy-ecc by Kenneth MacKay
'     BSD 2-clause license
'
'  2. https://github.com/ctz/cifra by Joseph Birr-Pixton
'     CC0 1.0 Universal license
'
'=========================================================================
Option Explicit
DefObj A-Z

#Const ImplUseLibSodium = (ASYNCSOCKET_USE_LIBSODIUM <> 0)
#Const ImplUseBCrypt = False

'=========================================================================
' API
'=========================================================================

Private Const TLS_SIGNATURE_RSA_PKCS1_SHA1              As Long = &H201
Private Const TLS_SIGNATURE_RSA_PKCS1_SHA256            As Long = &H401
'--- for CryptAcquireContext
Private Const PROV_RSA_FULL                 As Long = 1
Private Const PROV_RSA_AES                  As Long = 24
Private Const CRYPT_VERIFYCONTEXT           As Long = &HF0000000
'--- for CryptDecodeObjectEx
Private Const X509_ASN_ENCODING             As Long = 1
Private Const PKCS_7_ASN_ENCODING           As Long = &H10000
Private Const X509_PUBLIC_KEY_INFO          As Long = 8
Private Const PKCS_RSA_PRIVATE_KEY          As Long = 43
Private Const PKCS_PRIVATE_KEY_INFO         As Long = 44
Private Const CRYPT_DECODE_ALLOC_FLAG       As Long = &H8000
'--- for CryptCreateHash
Private Const CALG_SHA1                     As Long = &H8004&
Private Const CALG_SHA_256                  As Long = &H800C&
'--- for CryptSignHash
Private Const AT_KEYEXCHANGE                As Long = 1
Private Const MAX_RSA_KEY                   As Long = 8192     '--- in bits
'--- for CryptVerifySignature
Private Const NTE_BAD_SIGNATURE             As Long = &H80090006
'--- for thunks
Private Const MEM_COMMIT                    As Long = &H1000
Private Const PAGE_EXECUTE_READWRITE        As Long = &H40

#If ImplUseBCrypt Then
    Private Const BCRYPT_SECP256R1_PARTSZ               As Long = 32
    Private Const BCRYPT_SECP256R1_PRIVATE_KEYSZ        As Long = BCRYPT_SECP256R1_PARTSZ * 3
    Private Const BCRYPT_SECP256R1_COMPRESSED_PUBLIC_KEYSZ As Long = 1 + BCRYPT_SECP256R1_PARTSZ
    Private Const BCRYPT_SECP256R1_UNCOMPRESSED_PUBLIC_KEYSZ As Long = 1 + BCRYPT_SECP256R1_PARTSZ * 2
    Private Const BCRYPT_SECP256R1_TAG_COMPRESSED_POS   As Long = 2
    Private Const BCRYPT_SECP256R1_TAG_COMPRESSED_NEG   As Long = 3
    Private Const BCRYPT_SECP256R1_TAG_UNCOMPRESSED     As Long = 4
    Private Const BCRYPT_ECDH_PUBLIC_P256_MAGIC         As Long = &H314B4345
    Private Const BCRYPT_ECDH_PRIVATE_P256_MAGIC        As Long = &H324B4345
#End If

Private Declare Sub CopyMemory Lib "kernel32" Alias "RtlMoveMemory" (Destination As Any, Source As Any, ByVal Length As Long)
Private Declare Sub FillMemory Lib "kernel32" Alias "RtlFillMemory" (Destination As Any, ByVal Length As Long, ByVal Fill As Byte)
Private Declare Function ArrPtr Lib "msvbvm60" Alias "VarPtr" (Ptr() As Any) As Long
Private Declare Function VirtualAlloc Lib "kernel32" (ByVal lpAddress As Long, ByVal dwSize As Long, ByVal flAllocationType As Long, ByVal flProtect As Long) As Long
Private Declare Function VirtualProtect Lib "kernel32" (ByVal lpAddress As Long, ByVal dwSize As Long, ByVal flNewProtect As Long, ByRef lpflOldProtect As Long) As Long
Private Declare Function GetModuleHandle Lib "kernel32" Alias "GetModuleHandleA" (ByVal lpModuleName As String) As Long
Private Declare Function LoadLibrary Lib "kernel32" Alias "LoadLibraryA" (ByVal lpLibFileName As String) As Long
Private Declare Function LocalFree Lib "kernel32" (ByVal hMem As Long) As Long
Private Declare Function CryptAcquireContext Lib "advapi32" Alias "CryptAcquireContextW" (phProv As Long, ByVal pszContainer As Long, ByVal pszProvider As Long, ByVal dwProvType As Long, ByVal dwFlags As Long) As Long
Private Declare Function CryptReleaseContext Lib "advapi32" (ByVal hProv As Long, ByVal dwFlags As Long) As Long
Private Declare Function CryptGenRandom Lib "advapi32" (ByVal hProv As Long, ByVal dwLen As Long, ByVal pbBuffer As Long) As Long
Private Declare Function CryptImportKey Lib "advapi32" (ByVal hProv As Long, pbData As Any, ByVal dwDataLen As Long, ByVal hPubKey As Long, ByVal dwFlags As Long, phKey As Long) As Long
Private Declare Function CryptDestroyKey Lib "advapi32" (ByVal hKey As Long) As Long
Private Declare Function CryptCreateHash Lib "advapi32" (ByVal hProv As Long, ByVal AlgId As Long, ByVal hKey As Long, ByVal dwFlags As Long, phHash As Long) As Long
Private Declare Function CryptHashData Lib "advapi32" (ByVal hHash As Long, pbData As Any, ByVal dwDataLen As Long, ByVal dwFlags As Long) As Long
Private Declare Function CryptDestroyHash Lib "advapi32" (ByVal hHash As Long) As Long
Private Declare Function CryptSignHash Lib "advapi32" Alias "CryptSignHashA" (ByVal hHash As Long, ByVal dwKeySpec As Long, ByVal szDescription As Long, ByVal dwFlags As Long, pbSignature As Any, pdwSigLen As Long) As Long
Private Declare Function CryptVerifySignature Lib "advapi32" Alias "CryptVerifySignatureA" (ByVal hHash As Long, pbSignature As Any, ByVal dwSigLen As Long, ByVal hPubKey As Long, ByVal szDescription As Long, ByVal dwFlags As Long) As Long
Private Declare Function CryptEncrypt Lib "advapi32" (ByVal hKey As Long, ByVal hHash As Long, ByVal Final As Long, ByVal dwFlags As Long, pbData As Any, pdwDataLen As Long, dwBufLen As Long) As Long
Private Declare Function CryptImportPublicKeyInfo Lib "crypt32" (ByVal hCryptProv As Long, ByVal dwCertEncodingType As Long, pInfo As Any, phKey As Long) As Long
Private Declare Function CryptDecodeObjectEx Lib "crypt32" (ByVal dwCertEncodingType As Long, ByVal lpszStructType As Long, pbEncoded As Any, ByVal cbEncoded As Long, ByVal dwFlags As Long, ByVal pDecodePara As Long, pvStructInfo As Any, pcbStructInfo As Long) As Long
Private Declare Function CryptEncodeObjectEx Lib "crypt32" (ByVal dwCertEncodingType As Long, ByVal lpszStructType As Long, pvStructInfo As Any, ByVal dwFlags As Long, ByVal pEncodePara As Long, pvEncoded As Any, pcbEncoded As Long) As Long
Private Declare Function CertCreateCertificateContext Lib "crypt32" (ByVal dwCertEncodingType As Long, pbCertEncoded As Any, ByVal cbCertEncoded As Long) As Long
Private Declare Function CertFreeCertificateContext Lib "crypt32" (ByVal pCertContext As Long) As Long
#If ImplUseLibSodium Then
    '--- libsodium
    Private Declare Function sodium_init Lib "libsodium" () As Long
    Private Declare Function randombytes_buf Lib "libsodium" (ByVal lpOut As Long, ByVal lSize As Long) As Long
    Private Declare Function crypto_scalarmult_curve25519 Lib "libsodium" (lpOut As Any, lpConstN As Any, lpConstP As Any) As Long
    Private Declare Function crypto_scalarmult_curve25519_base Lib "libsodium" (lpOut As Any, lpConstN As Any) As Long
    Private Declare Function crypto_hash_sha256 Lib "libsodium" (lpOut As Any, lpConstIn As Any, ByVal lSize As Long, Optional ByVal lHighSize As Long) As Long
    Private Declare Function crypto_hash_sha256_init Lib "libsodium" (lpState As Any) As Long
    Private Declare Function crypto_hash_sha256_update Lib "libsodium" (lpState As Any, lpConstIn As Any, ByVal lSize As Long, Optional ByVal lHighSize As Long) As Long
    Private Declare Function crypto_hash_sha256_final Lib "libsodium" (lpState As Any, lpOut As Any) As Long
    Private Declare Function crypto_hash_sha512_init Lib "libsodium" (lpState As Any) As Long
    Private Declare Function crypto_hash_sha512_update Lib "libsodium" (lpState As Any, lpConstIn As Any, ByVal lSize As Long, Optional ByVal lHighSize As Long) As Long
    Private Declare Function crypto_hash_sha512_final Lib "libsodium" (lpState As Any, lpOut As Any) As Long
    Private Declare Function crypto_aead_chacha20poly1305_ietf_decrypt Lib "libsodium" (lpOut As Any, lOutSize As Any, ByVal nSec As Long, lConstIn As Any, ByVal lInSize As Long, ByVal lHighInSize As Long, lpConstAd As Any, ByVal lAdSize As Long, ByVal lHighAdSize As Long, lpConstNonce As Any, lpConstKey As Any) As Long
    Private Declare Function crypto_aead_chacha20poly1305_ietf_encrypt Lib "libsodium" (lpOut As Any, lOutSize As Any, lConstIn As Any, ByVal lInSize As Long, ByVal lHighInSize As Long, lpConstAd As Any, ByVal lAdSize As Long, ByVal lHighAdSize As Long, ByVal nSec As Long, lpConstNonce As Any, lpConstKey As Any) As Long
    Private Declare Function crypto_aead_aes256gcm_is_available Lib "libsodium" () As Long
    Private Declare Function crypto_aead_aes256gcm_decrypt Lib "libsodium" (lpOut As Any, lOutSize As Any, ByVal nSec As Long, lConstIn As Any, ByVal lInSize As Long, ByVal lHighInSize As Long, lpConstAd As Any, ByVal lAdSize As Long, ByVal lHighAdSize As Long, lpConstNonce As Any, lpConstKey As Any) As Long
    Private Declare Function crypto_aead_aes256gcm_encrypt Lib "libsodium" (lpOut As Any, lOutSize As Any, lConstIn As Any, ByVal lInSize As Long, ByVal lHighInSize As Long, lpConstAd As Any, ByVal lAdSize As Long, ByVal lHighAdSize As Long, ByVal nSec As Long, lpConstNonce As Any, lpConstKey As Any) As Long
    Private Declare Function crypto_hash_sha512_statebytes Lib "libsodium" () As Long
#End If
#If ImplUseBCrypt Then
    '--- BCrypt
    Private Declare Function BCryptOpenAlgorithmProvider Lib "bcrypt" (ByRef hAlgorithm As Long, ByVal pszAlgId As Long, ByVal pszImplementation As Long, ByVal dwFlags As Long) As Long
    Private Declare Function BCryptCloseAlgorithmProvider Lib "bcrypt" (ByVal hAlgorithm As Long, ByVal dwFlags As Long) As Long
    Private Declare Function BCryptImportKeyPair Lib "bcrypt" (ByVal hAlgorithm As Long, ByVal hImportKey As Long, ByVal pszBlobType As Long, ByRef hKey As Long, ByVal pbInput As Long, ByVal cbInput As Long, ByVal dwFlags As Long) As Long
    Private Declare Function BCryptExportKey Lib "bcrypt" (ByVal hKey As Long, ByVal hExportKey As Long, ByVal pszBlobType As Long, ByVal pbOutput As Long, ByVal cbOutput As Long, ByRef cbResult As Long, ByVal dwFlags As Long) As Long
    Private Declare Function BCryptDestroyKey Lib "bcrypt" (ByVal hKey As Long) As Long
    Private Declare Function BCryptSecretAgreement Lib "bcrypt" (ByVal hPrivKey As Long, ByVal hPubKey As Long, ByRef phSecret As Long, ByVal dwFlags As Long) As Long
    Private Declare Function BCryptDestroySecret Lib "bcrypt" (ByVal hSecret As Long) As Long
    Private Declare Function BCryptDeriveKey Lib "bcrypt" (ByVal hSharedSecret As Long, ByVal pwszKDF As Long, ByVal pParameterList As Long, ByVal pbDerivedKey As Long, ByVal cbDerivedKey As Long, ByRef pcbResult As Long, ByVal dwFlags As Long) As Long
    Private Declare Function BCryptGenerateKeyPair Lib "bcrypt" (ByVal hAlgorithm As Long, ByRef hKey As Long, ByVal dwLength As Long, ByVal dwFlags As Long) As Long
    Private Declare Function BCryptFinalizeKeyPair Lib "bcrypt" (ByVal hKey As Long, ByVal dwFlags As Long) As Long
#End If

Private Type CRYPT_DER_BLOB
    cbData              As Long
    pbData              As Long
End Type

'=========================================================================
' Constants and member variables
'=========================================================================

Private Const STR_GLOB                  As String = "////////////////AAAAAAAAAAAAAAAAAQAAAP////9LYNInPjzOO/awU8ywBh1lvIaYdlW967Pnkzqq2DXGWpbCmNhFOaH0oDPrLYF9A3fyQKRj5ea8+EdCLOHy0Rdr9VG/N2hAtsvOXjFrVzPOKxaeD3xK6+eOm38a/uJC409RJWP8wsq584SeF6et+ua8//////////8AAAAA/////5gvikKRRDdxz/vAtaXbtelbwlY58RHxWaSCP5LVXhyrmKoH2AFbgxK+hTEkw30MVXRdvnL+sd6Apwbcm3Txm8HBaZvkhke+78adwQ/MoQwkbyzpLaqEdErcqbBc2oj5dlJRPphtxjGoyCcDsMd/Wb/zC+DGR5Gn1VFjygZnKSkUhQq3JzghGy78bSxNEw04U1RzCmW7Cmp2LsnCgYUscpKh6L+iS2YaqHCLS8KjUWzHGeiS0SQGmdaFNQ70cKBqEBbBpBkIbDceTHdIJ7W8sDSzDBw5SqrYTk/KnFvzby5o7oKPdG9jpXgUeMiECALHjPr/vpDrbFCk96P5vvJ4ccYirijXmC+KQs1l7yORRDdxLztN7M/7wLW824mBpdu16Ti1SPNbwlY5GdAFtvER8VmbTxmvpII/khiBbdrVXhyrQgIDo5iqB9i+b3BFAVuDEoyy5E6+hTEk4rT/1cN9DFVviXvydF2+crGWFjv+sd6ANRLHJacG3JuUJmnPdPGbwdJK8Z7BaZvk4yVPOIZHvu+11YyLxp3BD2WcrHfMoQwkdQIrWW8s6S2D5KZuqoR0StT7Qb3cqbBctVMRg9qI+Xar32buUlE+mBAytC1txjGoPyH7mMgnA7DkDu++x39Zv8KPqD3zC+DGJacKk0eRp9VvggPgUWPKBnBuDgpnKSkU/C/S" & _
                                                    "RoUKtycmySZcOCEbLu0qxFr8bSxN37OVnRMNOFPeY6+LVHMKZaiydzy7Cmp25q7tRy7JwoE7NYIUhSxykmQD8Uyh6L+iATBCvEtmGqiRl/jQcItLwjC+VAajUWzHGFLv1hnoktEQqWVVJAaZ1iogcVeFNQ70uNG7MnCgahDI0NK4FsGkGVOrQVEIbDcemeuO30x3SCeoSJvhtbywNGNaycWzDBw5y4pB40qq2E5z42N3T8qcW6O4stbzby5o/LLvXe6Cj3RgLxdDb2OleHKr8KEUeMiE7DlkGggCx4woHmMj+v++kOm9gt7rbFCkFXnGsvej+b4rU3Lj8nhxxpxhJurOPifKB8LAIce4htEe6+DN1n3a6njRbu5/T331um8Xcqpn8AammMiixX1jCq4N+b4EmD8RG0ccEzULcRuEfQQj9XfbKJMkx0B7q8oyvL7JFQq+njxMDRCcxGcdQ7ZCPsu+1MVMKn5l/Jwpf1ns+tY6q2/LXxdYR0qMGURsZXhwYW5kIDE2LWJ5dGUgawBleHBhbmQgMzItYnl0ZSBrAAAABQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPwAAABjfHd78mtvxTABZyv+16t2yoLJffpZR/Ct1KKvnKRywLf9kyY2P/fMNKXl8XHYMRUExyPDGJYFmgcSgOLrJ7J1CYMsGhtuWqBSO9azKeMvhFPRAO0g/LFbasu+OUpMWM/Q76r7Q00zhUX5An9QPJ+oUaNAj5KdOPW8ttohEP/z0s0ME+xfl0QXxKd+PWRdGXNggU/cIiqQiEbuuBTeXgvb4DI6CkkGJFzC06xikZXkeefIN22N1U6pb" & _
                                                    "Fb06mV6rgi6eCUuHKa0xujddB9LvYuKcD61ZkgD9g5hNVe5hsEdnuH4mBFp2Y6Umx6H6c5VKN+MoYkNv+ZCaEGZLQ+wVLsWjQECBAgQIECAGzZSCWrVMDalOL9Ao56B89f7fOM5gpsv/4c0jkNExN7py1R7lDKmwiM97kyVC0L6w04ILqFmKNkksnZboklti9Elcvj2ZIZomBbUpFzMXWW2kmxwSFD97bnaXhVGV6eNnYSQ2KsAjLzTCvfkWAW4s0UG0Cwej8o/DwLBr70DAROKazqREUFPZ9zql/LPzvC05nOWrHQi5601heL5N+gcdd9uR/EacR0pxYlvt2IOqhi+G/xWPkvG0nkgmtvA/njNWvQf3agziAfHMbESEFkngOxfYFF/qRm1Sg0t5Xqfk8mc76DgO02uKvWwyOu7PINTmWEXKwR+unfWJuFpFGNVIQx9AAAAAAA=" ' 1688, 19.4.2020 19:52:54
Private Const STR_THUNK1                As String = "MNGKABAuAADwMAAAUDEAAAAaAAAgHQAAoCYAAPAmAADQJAAAYCcAAPAnAAAwJwAAIBkAAOAYAAAwDgAAsA0AAOgAAAAAWC1FQIoABQBAigCLAMPMzMzMzMzMzMzMzMzM6AAAAABYLWVAigAFAECKAMPMzMzMzMzMzMzMzMzMzMxVi+yD7EhTi10QU+iATgAAhcAPhSkBAABWi3UMjUXYV1ZQ6MlUAACLfQiNRdhQV41FuFDoiFQAAI1F2FBQ6K5UAABTVlbodlQAAFNT6J9UAADoav///1BTV1fo4VEAAOhc////UFNTU+jTUQAA6E7///9QU1dT6KVUAABTV1foPVQAAOg4////UFdXU+ivUQAA6Cr///9QU1dX6KFRAABqAFfoKVoAAAvCdCDoEP///1BXV+jYSwAAV4vw6HBWAADB5h8JdxyLdQzrBlfoX1YAAFdT6BhUAADo4/7//1CNRbhQU1PoN1QAAOjS/v//UI1FuFBTU+gmVAAA6MH+//9QU41FuFBQ6BVUAACNRbhQV1foqlMAAOil/v//UI1F2FBXUOj5UwAAU1foYlYAAFZT6FtWAACNRdhQVuhRVgAAX15bi+VdwgwAzMzMzMzMzMxVi+xWi3UIVugzTQAAhcB0F41GIFDoJk0AAIXAdAq4AQAAAF5dwgQAM8BeXcIEAMxVi+yB7KgAAABTi10MjUW4VldTUOj3VQAAjUMgUIlF+I2FeP///1Do5FUAAP91FI2FWP///1CNRZhQjYV4////UI1FuFDohgMAAItdEFPo3VQAAIPoAolFFIXAflsPHwBQU+jpWAAAC8J1B7gBAAAA6wIzwMHgBY2dWP///wPYjU2YA8iNtXj///9T99iJTfxRA/CNfbgD+FZX6OEBAABWV1P/" & _
                                                    "dfzo9gAAAItFFItdEEiJRRSFwH+oagBT6JBYAAALwnUFjUgB6wIzycHhBY2dWP///wPZiU0QU41FmAPBjb14////UCv5jXW4K/FXVuiMAQAA6Ef9//9QjUWYUI1FuFCNRdhQ6JVSAABXjUXYUFDoKlIAAP91DI1F2FBQ6B1SAADoGP3//1CNRdhQUOjNTwAA/3X4jUXYUFDoAFIAAFaNRdhQUOj1UQAAV1aNRZgDRRBTUOhGAAAAjUXYUI2FWP///1CNRZhQ6KIFAACLdQiNRZhQVuiVVAAAjYVY////UI1GIFDohVQAAF9eW4vlXcIQAMzMzMzMzMzMzMzMzFWL7IPsIFNWV+iS/P//i10Ii3UQUFNWjUXgUOjgUQAAjUXgUFDoplEAAI1F4FBTU+hrUQAAjUXgUFZW6GBRAADoW/z//4t1DIt9FFBWV1forFEAAFeNReBQ6HJRAADoPfz//1BTjUXgUFDokVEAAOgs/P//UItFEFCNReBQUOh9UQAA6Bj8//9Qi0UQU1BQ6GxRAACLRRBQVlboAVEAAOj8+///UI1F4FBTi10QU+hNUQAAU1dX6OVQAADo4Pv//1BWV1foN1EAAI1F4FBT6J1TAABfXluL5V3CEADMzMzMVYvsg+xgU1ZX6LL7//+LXQiLfRBQU1eNRcBQ6ABRAACNRcBQUOjGUAAAjUXAUFNT6ItQAACNRcBQV1fogFAAAOh7+///i10Mi3UUUFNWjUXAUOjpTQAA6GT7//9QU1ZW6LtQAADoVvv//1D/dQiNReBXUOioUAAAjUXgUFNT6D1QAADoOPv//1BX/3UIjUXgUOiqTQAAVlfoU1AAAOge+///UI1F4FBXV+hyUAAA6A37//9QV4t9CI1FoFdQ6F5QA" & _
                                                    "ACNRaBQVlbo808AAOju+v//UFNWVuhFUAAAjUXAUI1FoFDoCFAAAOjT+v//UI1F4FCNRaBQUOgkUAAA6L/6//9QV41FoFCNReBQ6BBQAACNRcBQjUXgUFDook8AAOid+v//UFONReBQU+jxTwAAjUWgUFfoV1IAAF9eW4vlXcIQAMzMzMzMzMzMzMzMzMzMVYvsg+wgVot1CFdW/3UQ6CxSAACLfQxX/3UU6CBSAACNReBQ6FdIAACLRRjHReABAAAAx0XkAAAAAIXAdApQjUXgUOj4UQAAjUXgUFdW6O0CAACNReBQV1boUvr//41F4FD/dRT/dRDo0wIAAF9ei+VdwhQAzMzMzMzMzMzMzMxTi0QkDItMJBD34YvYi0QkCPdkJBQD2ItEJAj34QPTW8IQAMzMzMzMzMzMzMzMzMyA+UBzFYD5IHMGD6XC0+DDi9AzwIDhH9PiwzPAM9LDzID5QHMVgPkgcwYPrdDT6sOLwjPSgOEf0+jDM8Az0sPMVYvsi0UQU1aLdQiNSHhXi30MjVZ4O/F3BDvQcwuNT3g78XcwO9dyLCv4uxAAAAAr8IsUOAMQi0w4BBNIBI1ACIlUMPiJTDD8g+sBdeRfXltdwgwAi9eNSBCL3ivQK9gr/rgEAAAAjXYgjUkgDxBB0A8QTDfgZg/UyA8RTuAPEEwK4A8QQeBmD9TIDxFMC+CD6AF10l9eW13CDADMzMzMzFWL7ItVHIPsCItFIFaLdQhXi30MA9cTRRCJFolGBDtFEHcPcgQ713MJuAEAAAAzyesOD1fAZg8TRfiLTfyLRfgDRSRfE00oA0UUiUYIi8YTTRiJTgxei+VdwiQAzMzMzFWL7ItVDItNCIsCMQGLQgQxQQSLQggxQQiLQgwxQQ" & _
                                                    "xdwggAzMzMzMzMzMzMzMzMzFWL7IPsCItNCItVEFNWiwGNWQTB6gIz9olVEIld+I0EhQQAAACJRfxXhdJ0QotVDIt9EIPCAmZmDx+EAAAAAAAPtkr+jVIED7ZC+8HhCAvID7ZC/MHhCAvID7ZC/cHhCAvIiQyzRjv3ctaLRfyL17kBAAAAM/+JTQw78A+DjQAAAIvGK8KNBIOJRQgPH0QAAItcs/w7+nUIQTP/iU0M6wSF/3Ut6Kf3//8FiAQAAMHDCFBT6EhDAACL2OiR9///i00MD7aECIgFAADB4Bgz2Osdg/oGdh6D/wR1Gehw9///BYgEAABQU+gUQwAAi9iLRQiLVRCLCEczy4PABItd+IlFCIkMs0aLTQw7dfxygl9eW4vlXcIMAMzMzMzMzMzMzFWL7IPsII1F4P91EFDoTkwAAI1F4FCLRQhQUOgQTAAA/3UQjUXgUFDoA0wAAI1F4FCLRQxQUOj1SwAAi+VdwgwAzMzMzMzMzMzMzMzMzMzMVYvsg+wgU1aLdQgzyVeJTeyBBM4AAAEAiwTOg1TOBACLXM4ED6zYEMH7EIlF6IP5D3UVx0X8AQAAAIvQx0XwAAAAAIld+OsiD1fAZg8TRfSLRfiJRfCLRfRmDxNF4ItV4IlF/ItF5IlF+IP5D415AWoAG8D32A+vxytV/GoljTTGi0X4G0XwUFLoYvz//4tN6APBE9OD6AGD2gABBotF7BFWBIt1CA+kyxDB4RApDMaLz4lN7BlcxgSD+RAPgk////9fXluL5V3CBADMzMzMzFWL7IPsEItVDFZXD7YKD7ZCAcHhCAvID7ZCAsHhCAvID7ZCA8HhCAvID7ZCBYlN8A+2SgTB4QgLyA+2QgbB4QgLyA+2QgfB4QgLyA+" & _
                                                    "2QgmJTfQPtkoIweEIC8gPtkIKweEIC8gPtkILweEIC8gPtkIMiU34D7ZKDcHgCAvID7ZCDsHhCAvID7ZCD8HhCAvIiU38i00IizmNcQSLx8HgBAPwjUXwVlDo5fz//4PuEIPH/3QtjUXwUOgkKgAAjUXwUOi7KgAAVo1F8FDowfz//41F8FDoyCkAAIPuEIPvAXXTjUXwUOj3KQAAjUXwUOiOKgAAVo1F8FDolPz//4t1EItV8IvCi030wegYiAaLwsHoEIhGAYvCwegIiEYCi8HB6BiIVgOIRgSLwcHoEIhGBYvBwegIiEYGiE4Hi034i8HB6BiIRgiLwcHoEIhGCYvBwegIiEYKiE4Li038i8HB6BiIRgyLwcHoEIhGDYvBwegIiEYOX4hOD16L5V3CDADMzFWL7IPsEFNWV4tVDItdCA+2Cg+2QgHB4QiNcwQLyA+2QgLB4QgLyA+2QgPB4QgLyA+2QgWJTfAPtkoEweEIC8gPtkIGweEIC8gPtkIHweEIC8gPtkIJiU30D7ZKCMHhCAvID7ZCCsHhCAvID7ZCC8HhCAvID7ZCDIlN+A+2Sg3B4AgLyA+2Qg7B4QgLyA+2Qg/B4QgLyI1F8FZQiU386G37//+/AQAAAIPGEDk7di6QjUXwUOgXPwAAjUXwUOiuPQAAjUXwUOg1KgAAVo1F8FDoO/v//0eDxhA7O3LTjUXwUOjqPgAAjUXwUOiBPQAAVo1F8FDoF/v//4t1EItV8IvCi030wegYiAaLwsHoEIhGAYvCwegIiEYCi8HB6BiIVgOIRgSLwcHoEIhGBYvBwegIiEYGiE4Hi034i8HB6BiIRgiLwcHoEIhGCYvBwegIiEYKiE4Li038i8HB6BiIRgyLwcHoEIhGDYvB" & _
                                                    "wegIiEYOX4hOD15bi+VdwgwAzMzMzFWL7FaLdQho9AAAAGoAVugMKQAAi0UQg8QMg/gQdDyD+Bh0IYP4IHQG/xXUsIoAaiD/dQzHBg4AAABW6ID6//9eXcIMAGoY/3UMxwYMAAAAVuhq+v//Xl3CDABqEP91DMcGCgAAAFboVPr//15dwgwAzMzMzMzMzMzMzMzMzMzMVYvsgewAAQAAVuih8v//vrBLigCB7gBAigAD8OiP8v///3UouTBKigDHRfQQAAAA/3UkgekAQIoAiXX4A8GJRfyNhQD///9Q6DP/////dQiNhQD///9qEP91FGoM/3Ug/3Uc/3UY/3UQ/3UMUI1F9FDoOg8AAF6L5V3CJADMzMxVi+yB7AABAABW6CHy//++sEuKAIHuAECKAAPw6A/y////dSi5MEqKAMdF9BAAAAD/dSSB6QBAigCJdfgDwYlF/I2FAP///1Dos/7//2oQ/3UMjYUA/////3UIagz/dSD/dRz/dRj/dRT/dRBQjUX0UOh6EAAAXovlXcIkAMzMzFWL7FFTi10YM8CJRfyF23Rxi1UQi00MVsdFGAEAAABXizmL8iv3O94PQvOFwHUdD7ZFFFZQi0UIA8dQ6GAnAACLTQyDxAyLRfyLVRCF/3UJO/IPREUYiUX8jQQ+O8J1F/91CP91IP9VHItNDItVEMcBAAAAAOsCATGLRfwr3nWgX15bi+VdwhwAzMzMzMzMzFWL7FaLdSCLxoPoAHRgg+gBD4SsAAAAU4PoAVeNRRR0bYt9KItdJFdTagFQ/3UQ/3UM/3UI6LYAAACLTRhXUzhNHHQvjUb+i3UQUFFW/3UM/3UI6Bj///9XU2oBjUUcUFb/dQz/dQjohAAAAF9bXl3CJACNRv+Ld" & _
                                                    "RBQUVb/dQz/dQjo6f7//19bXl3CJAD/dSiLXRD/dSSLfQyLdQhqAVBTV1boSAAAAP91KI1FHP91JGoBUFNXVug0AAAAX1teXcIkAP91KIpFHP91JDBFFI1FFGoBUP91EP91DP91COgNAAAAXl3CJADMzMzMzMzMzFWL7P91IItFHFBQ/3UY/3UU/3UQ/3UM/3UI6BEAAABdwhwAzMzMzMzMzMzMzMzMzFWL7ItNDItFJFOLXRSLEVaLdRhXhdJ0WYX2dFWLRRCL/ivCO8YPQviLwgNFCFdTUOiLJQAAi0UMA98r94PEDAE4i30QOTiLRSR1Kf91CFCF9nUN/1Ugi00Mi0UkiTHrFP9VHItNDItFJMcBAAAAAOsDi30QO/dyGVNQO/d1Bf9VIOsD/1Uci0UkK/cD3zv3c+eF9nQui0UMiwiLxyvBi/47xg9C+ItFCFcDwVNQ6A4lAACLRQwD34PEDAE4K/eLfRB11V9eW13CIADMzMzMzMxVi+yLTRyD7AhXi30Yhcl0dlOLXQxWgzsAdRH/dQj/dST/VSCLRRCLTRyJA4sDi/GLVRAr0DvBiVUYD0LwM8CJdfyF9nQvi10UK9+JXfhmkIt1/I0UOIoME4tVGANVCItd+DIMAo0UOECICjvGcuGLXQyLTRwpMyvOAXUUA/6JTRyFyXWRXltfi+VdwiAAzMxVi+zomO7//7mgWIoAgekAQIoAA8GLTQhRUP91FI1BdP91EP91DGpAUI1BNFDoPv///13CEADMzMzMzMzMzMzMVYvsg+xsi00UU1ZXD7ZZAw+2QQIPtlEHweIIweMIC9gPtkEBweMIC9gPtgHB4wgL2A+2QQYL0Ild2MHiCA+2QQUL0A+2QQTB4ggL0A+2QQqJVfSJVd" & _
                                                    "QPtlELweIIC9APtkEJweIIC9APtkEIweIIC9APtkEOiVXwiVXQD7ZRD8HiCAvQD7ZBDcHiCAvQD7ZBDItNCMHiCAvQiVX4D7ZBAolVzA+2UQPB4ggL0A+2QQHB4ggL0A+2AcHiCAvQD7ZBBolV7IlVyA+2UQfB4ggL0A+2QQXB4ggL0A+2QQTB4ggL0A+2QQqJVeiJVcQPtlELweIIC9DB4ggPtkEJC9APtkEIweIIC9APtkEOiVXkiVXAD7ZRD8HiCAvQD7ZBDcHiCAvQD7ZBDItNDMHiCAvQiVXgD7ZBAolVvA+2UQPB4ggL0A+2QQHB4ggL0A+2AcHiCAvQD7ZBBolVCIlVuA+2UQfB4ggL0A+2QQXB4ggL0A+2QQTB4ggL0A+2QQqJVRSJVbQPtlELweIIC9APtkEJweIIC9APtkEIweIIC9APtkEOiVUMiVWwD7ZRD8HiCAvQD7ZBDcHiCAvQD7ZBDMHiCAvQiVX8iVWsi1UQD7ZKAw+2QgLB4QgLyA+2QgHB4QgLyA+2AsHhCAvIiU3ciU2oD7ZyBw+2QgYPtnoLD7ZKDsHmCAvwwecID7ZCBcHmCAvwx0WYCgAAAA+2QgTB5ggL8A+2QgoL+Il1pA+2QgnB5wgL+A+2QgjB5wgL+A+2Qg/B4AgLwYl9oA+2Sg3B4AgLwQ+2SgyLVdzB4AgLwYtN7IlFnOsDi10QA9mLTQgz04ldEMHCEAPKiU0IM03swcEMA9kz04ldEItdCMHCCAPaiVXci1X0A1XoM/KJXQgz2cHGEItNFAPOwcMHiU0UM03owcEMA9Ez8olV9ItVFMHGCAPWiXXsi3XwA3XkM/6JVRQz0cHHEItNDAPPwcIHiU0MM03kwcEMA/Ez/ol18It1DMHHCAP" & _
                                                    "3iX2Ui334A33gM8eJdQwz8cHAEItN/APIwcYHiU38M03gwcEMA/kzx4l9+It9/MHACAP4iX38M/mLTRADysHHBzPBiU0Qi00MwcAQA8iJTQwzyotVEMHBDAPRM8KJVRCLVQzBwAgD0IlVDDPRi030A87BwgeJTfSJVeiLVdwz0YtN/MHCEAPKiU38M86LdfTBwQwD8TPWiXX0i3X8wcIIA/KJdfwz8YtN8APPwcYHiU3wiXXki3XsM/GLTQjBxhADzolNCDPPi33wwcEMA/kz94l98It9CMHGCAP+iX0IM/mLTfgDy8HHB4l94It9lDP5iU34i00UwccQA8+JTRQzy4td+MHBDAPZM/uJXfjBxwgBfRSLXRQz2YvLiV3swcEHg22YAYtd+IlN7A+FQP7//wFFnAFdzItN2ANNEAFVqItVGIlN2Itd2IvDi03UA030iBqJTdSLTdADTfDB6AiIQgGLw4lN0ItN7AFNyItNxANN6MHoEIhCAsHrGIhaA4td1IvDiFoEwegIiEIFi8OJTcSLTcADTeTB6BCIQgaJTcCLTbwDTeABdaQBfaDB6xiIWgeLXdCLw4haCIlNvItNuANNCMHoCIhCCYvDiU24i020A00UwegQiEIKwesYiFoLi13Mi8OJTbSLTbADTQyIWgzB6AiIQg2Lw4lNsItNrANN/MHoEIhCDsHrGIhaD4tdyIvDiU2siFoQwegIiEIRi8PB6BCIQhLB6xiIWhOLXcSLw4haFMHoCIhCFYvDwegQiEIWwesYiFoXi13Ai8OIWhjB6AiIQhmLw8HoEIhCGsHrGIhaG4tdvIvDiFocwegIiEIdi8PB6BCIQh7B6xiIWh+LXbiLw4haIMHoCIhCIYvDwegQiEIiwesYiFoj" & _
                                                    "i120i8OIWiTB6AiIQiWLw8HoEIhCJsHrGIhaJ4tdsIvDiFoowegIiEIpi8PB6BCIQirB6xiIWiuL2YhaLIvDwegIiEIti8PB6BCIQi7B6xiIWi+LXaiLw4haMMHoCIhCMY1KPIvDwesYwegQiEIyiFozi12ki8OIWjTB6AiIQjWLw8HoEIhCNsHrGIhaN4tdoIvDiFo4wegIiEI5i8PB6BCIQjrB6xiIWjuLVZyLwsHoCIgRiEEBi8JfwegQweoYXohBAohRA1uL5V3CFADMVYvsVv91EIt1CP91DFbobSsAAGoQ/3UUjUYgUOifHQAAi0UYg8QMx0Z0AAAAAIlGeF5dwhQAzMzMzMzMzMzMzFWL7FaLdQhX/3UM/3YwjX4gV41GEFBW6ET5//+LVngzwIAHAXULQDvCdAaABDgBdPVfXl3CCADMzMzMzMzMzMxVi+yD7BCNRfBqEP91IFDoLB0AAIPEDI1F8FBqAP91JP91HP91GP91FP91EP91DP91COgZJgAAi+VdwiAAzMzMVYvs/3UkagH/dSD/dRz/dRj/dRT/dRD/dQz/dQjo7iUAAF3CIADMzMzMzMzMzMzMVYvs6Ajn//+5wGuKAIHpAECKAAPBi00IUVD/dRSLAf91EP91DP8wjUEoUI1BGFDorPf//13CEADMzMzMzMzMzFWL7ItNCItFDIlBLItFEIlBMF3CDADMzMzMzMzMzMzMVYvsVot1CGo0agBW6I8cAACLTQzHRiwAAAAAiwGJRjCLRRCJRgSNRgiJDsdGKAAAAAD/Mf91FFDoMxwAAIPEGF5dwhAAzMzMzMzMzMzMzMxVi+yB7CAEAABTVldqcI2FcP3//8eFYP3//0HbAABqAFDHhWT9//8AAAAAx4Vo/" & _
                                                    "f//AQAAAMeFbP3//wAAAADoDBwAAIt1DI2FYP///2ofVlDoyhsAAIpGH4PEGIClYP////gkPwxAiIV/////jYXg+////3UQUOjEMQAAD1fAjbVg/v//Zg8ThWD+//+NvWj+//+5HgAAAGYPE0WA86W5HgAAAGYPE4Xg/v//jXWAx4Vg/v//AQAAAI19iMeFZP7//wAAAADzpbkeAAAAx0WAAQAAAI214P7//8dFhAAAAACNvej+//+7/gAAAPOluSAAAACNteD7//+NveD9///zpYvDD7bLwfgDg+EHD7a0BWD///+NheD9///T7oPmAVZQjUWAUOiWJwAAVo2FYP7//1CNheD+//9Q6IInAACNheD+//9QjUWAUI2F4Pz//1Doa+v//42F4P7//1CNRYBQUOh6LwAAjYVg/v//UI2F4P3//1CNheD+//9Q6EDr//+NhWD+//9QjYXg/f//UFDoTC8AAI2F4Pz//1CNhWD+//9Q6BkvAACNRYBQjYVg/P//UOgJLwAAjUWAUI2F4P7//1CNRYBQ6MUbAACNheD8//9QjYXg/f//UI2F4P7//1DoqxsAAI2F4P7//1CNRYBQjYXg/P//UOjE6v//jYXg/v//UI1FgFBQ6NMuAACNRYBQjYXg/f//UOijLgAAjYVg/P//UI2FYP7//1CNheD+//9Q6KkuAACNhWD9//9QjYXg/v//UI1FgFDoQhsAAI2FYP7//1CNRYBQUOhh6v//jUWAUI2F4P7//1BQ6CAbAACNhWD8//9QjYVg/v//UI1FgFDoCRsAAI2F4Pv//1CNheD9//9QjYVg/v//UOjvGgAAjYXg/P//UI2F4P3//1DoDC4AAFaNheD9//9QjUWAUOj7JQAAVo2FYP7//1" & _
                                                    "CNheD+//9Q6OclAACD6wEPiR/+//+NheD+//9QUOgxFwAAjYXg/v//UI1FgFBQ6JAaAACNRYBQ/3UI6OQcAABfXluL5V3CDADMzMzMzMzMzMzMzFWL7IPsII1F4MZF4AlQ/3UMD1fAx0X5AAAAAP91CA8RReFmx0X9AABmD9ZF8cZF/wDoqvz//4vlXcIIAMzMzMxVi+yB7BQBAABTi10IjUXwVleLfQwPV8BQUItDBFfGRfAAZg/WRfHHRfkAAAAAZsdF/QAAxkX/AP/Qi3Ukg/4MdSBW/3UgjUXQUOhxGAAAg8QMZsdF3QAAxkXcAMZF3wHrMI1F8FCNhez+//9Q6B4WAABW/3UgjYXs/v//UOg+FAAAjUXQUI2F7P7//1Do7hQAAI1F8FCNhTz///9Q6O4VAAD/dRyNhTz/////dRhQ6OwTAACNRdDGReAAUFdTjUWMx0XpAAAAAA9XwGbHRe0AAFBmD9ZF4cZF7wDocPv//2oEagyNRYxQ6EP7//9qEI1F4FBQjUWMUOjz+v///3UUjYU8/////3UQUOixEwAAjUXAUI2FPP///1DoYRQAAIt1LI1F4FZQjUXAUFDo/zwAADLSjUXAuwEAAACF9nQai30oi8gr+YoMB41AATJI/wrRK/N18YTSdRT/dRSNRYz/dTD/dRBQ6IX6//8z2w9XwA8RRfCKRfAPEUXQikXQDxFF4IpF4A8RRcCKRcBqUI2FPP///2oAUOhUFwAAio08////jUWMajRqAFDoQRcAAIpNjIPEGIvDX15bi+VdwiwAVYvsgewUAQAAU4tdCI1F8FZXi30MD1fAUFCLQwRXxkXwAGYP1kXxx0X5AAAAAGbHRf0AAMZF/wD/0It1JIP+DHUgVv91II1F0FD" & _
                                                    "osRYAAIPEDGbHRd0AAMZF3ADGRd8B6zCNRfBQjYXs/v//UOheFAAAVv91II2F7P7//1DofhIAAI1F0FCNhez+//9Q6C4TAACNRfBQjYU8////UOguFAAA/3UcjYU8/////3UYUOgsEgAAjUXQxkXgAFBXU41FjMdF6QAAAAAPV8Bmx0XtAABQZg/WReHGRe8A6LD5//9qBGoMjUWMUOiD+f//ahCNReBQUI1FjFDoM/n//4t9FI1FjIt1KFdW/3UQUOgf+f//V1aNhTz///9Q6OERAACNRcDGRcAAUI2FPP///8dFyQAAAAAPV8Bmx0XNAABQZg/WRcHGRc8A6HQSAAD/dTCNReBQjUXAUP91LOgROwAAD1fADxFF8IpF8A8RRdCKRdAPEUXgikXgDxFFwIpFwGpQjYU8////agBQ6KIVAACKhTz///9qNI1FjGoAUOiPFQAAikWMg8QYX15bi+VdwiwAVYvsi1UMi00QVot1CIsGMwKJAYtGBDNCBIlBBItGCDNCCIlBCItGDDNCDIlBDF5dwgwAzMzMzMzMzMzMzMzMzFWL7FFTi10MVleLfQhmx0X8AOGLD4vB0eiD4QGJA4tXBIvC0eiD4gHB4R8LyMHiH4lLBIt3CIvG0eiD5gEL0MHmH4lTCItPDIvB0eiD4QEL8F+JcwwPtkQN/MHgGDEDXluL5V3CCADMzMzMzMzMzMxVi+yLVQxWi3UID7YOD7ZGAcHhCAvID7ZGAsHhCAvID7ZGA8HhCAvIiQoPtk4ED7ZGBcHhCAvID7ZGBsHhCAvID7ZGB8HhCAvIiUoED7ZOCA+2RgnB4QgLyA+2RgrB4QgLyA+2RgvB4QgLyIlKCA+2TgwPtkYNweEIC8gPtkYOweEIC8gPtkYP" & _
                                                    "weEIC8iJSgxeXcIIAMzMzMzMzMzMzMzMVYvsg+wgVldqEI1F4GoAUOgbFAAAahD/dQyNRfBQ6N0TAACLfQiDxBgPEE3gM/aQi8a5HwAAAIPgHyvIi8bB+AWLBIfT6KgBdAwPEEXwZg/vyA8RTeCNRfBQUOiQ/v//RoH+gAAAAHzHahCNReBQ/3UQ6IkTAACDxAxfXovlXcIMAMzMzMzMzMzMzMzMzMzMVYvsVot1DFeLfQiLF4vCwegYiAaLwsHoEIhGAYvCwegIiEYCiFYDi08Ei8HB6BiIRgSLwcHoEIhGBYvBwegIiEYGiE4Hi08Ii8HB6BiIRgiLwcHoEIhGCYvBwegIiEYKiE4Li08Mi8HB6BiIRgyLwcHoEIhGDYvBwegIiEYOX4hOD15dwggAzMzMzMzMzMzMVYvsg+xEVot1CIO+qAAAAAB0BlbohxkAADPJDx9EAAAPtoQOiAAAAIlEjbxBg/kQcu5Wx0X8AAAAAOhhGAAAjUW8UFbo9xcAAItVDDPJZpCKBI6IBBFBg/kQcvRorAAAAGoAVuinEgAAigaDxAxei+VdwggAzMzMzMzMzMzMzMxVi+xWi3UIaKwAAABqAFbofBIAAItNDGoQ/3UQD7YBiUZED7ZBAYlGSA+2QQKJRkwPtkEDg+APiUZQD7ZBBCX8AAAAiUZUD7ZBBYlGWA+2QQaJRlwPtkEHg+APiUZgD7ZBCCX8AAAAiUZkD7ZBCYlGaA+2QQqJRmwPtkELg+APiUZwD7ZBDCX8AAAAiUZ0D7ZBDYlGeA+2QQ6JRnwPtkEPg+APx4aEAAAAAAAAAImGgAAAAI2GiAAAAFDooREAAIPEGF5dwgwAzMzMzMzMzMzMVYvs6Mjb//+58H6KAIHpAECKAAPBi"
Private Const STR_THUNK2                As String = "00IUVD/dRCNgagAAAD/dQxqEFCNgZgAAABQ6Gvr//9dwgwAzMzMzMzMzFWL7IPsGFNWV+iC2////3UIvmCEigC5QAAAAIHuAECKAAPwi0UIVo14ZItAYPfhAweL2IPSAIPACIPgPyvIUWoAagBogAAAAGpAV4t9CA+k2gOJVfyNRyDB4wNQiVX46Azq//+LVfyLy4vCiF3vwegYiEXoi8LB6BCIRemLwsHoCIhF6opF+IhF64vCD6zBGGoIwegYiE3si8KLyw+swRDB6BCLw4hN7Q+s0AiIRe6NRehQweoIV+hkAQAAixeLwot1DMHoGIgGi8LB6BCIRgGLwsHoCIhGAohWA4tPBIvBwegYiEYEi8HB6BCIRgWLwcHoCIhGBohOB4tPCIvBwegYiEYIi8HB6BCIRgmLwcHoCIhGCohOC4tPDIvBwegYiEYMi8HB6BCIRg2LwcHoCIhGDohOD4tPEIvBwegYiEYQi8HB6BCIRhGLwcHoCIhGEohOE4tPFIvBwegYiEYUi8HB6BCIRhWLwcHoCIhGFohOF4tPGIvBwegYiEYYi8HB6BCIRhmLwcHoCIhGGohOG4tPHIvBwegYiEYci8HB6BCIRh2LwWpowegIagCIRh5XiE4f6MkPAACDxAxfXluL5V3CCADMzMzMzMzMzMzMzMzMVYvsVot1CGpoagBW6J8PAACDxAzHBmfmCWrHRgSFrme7x0YIcvNuPMdGDDr1T6XHRhB/Ug5Rx0YUjGgFm8dGGKvZgx/HRhwZzeBbXl3CBABVi+zoaNn//7lghIoAgekAQIoAA8GLTQhRUP91EI1BZP91DGpAUI1BIFDoEen//13CDADMzMzMzMzMzMzMzMzMVYvsg+xAjUXAUP91COi+AAAAaj" & _
                                                    "CNRcBQ/3UM6NAOAACDxAyL5V3CCADMzMzMzMzMVYvsVot1CGjIAAAAagBW6NwOAACDxAzHBtieBcHHRgRdnbvLx0YIB9V8NsdGDCopmmLHRhAX3XAwx0YUWgFZkcdGGDlZDvfHRhzY7C8Vx0YgMQvA/8dGJGcmM2fHRigRFVhox0Ysh0q0jsdGMKeP+WTHRjQNLgzbx0Y4pE/6vsdGPB1ItUdeXcIEAMzMzMzM6YsDAADMzMzMzMzMzMzMzFWL7IPsHItFCFONmMQAAABWi4DAAAAAV7+AAAAA9+eL8AMzi8aD0gAPpMIDweADiVX8iUX4iVX06CPY////dQi5MIaKAIHpAECKAAPBUI1GEIt1CIPgfyv4V2oAagBogAAAAGiAAAAAU41GQFDozub//2oIjUXkx0XkAAAAAFBWx0XoAAAAAOj0AgAAi138i8OLVfiLysHoGIhF5IvDwegQiEXli8PB6AiIReaKRfSIReeLww+swRhqCMHoGIhN6IvDi8qIVesPrMEQwegQi8KITekPrNgIiEXqjUXkUFbB6wjomQIAAIteBIvDiw6JTfzB6BiLfQyIB4vDwegQiEcBi8PB6AiIRwKLww+swRiIXwPB6BiITwSLw4tN/A+swRDB6BCITwWLTfyLwQ+s2AiIRwaLxohPB8HrCItYCIvLi1AMi8LB6BiIRwiLwsHoEIhHCYvCwegIiEcKi8IPrMEYiFcLwegYiE8Mi8KLyw+swRDB6BCITw2Lww+s0AiIRw6LxohfD8HqCItYEIvLi1AUi8LB6BiIRxCLwsHoEIhHEYvCwegIiEcSi8IPrMEYiFcTwegYiE8Ui8KLyw+swRDB6BCLw4hPFQ+s0AiIRxaLxsHqCIhfF4tYGIvLi1Aci8L" & _
                                                    "B6BiIRxiLwsHoEIhHGYvCwegIiEcai8IPrMEYiFcbwegYiE8ci8KLyw+swRDB6BCITx2Lww+s0AiIRx6LxohfH8HqCItYIIvLi1Aki8LB6BiIRyCLwsHoEIhHIYvCwegIiEcii8IPrMEYiFcjwegYiE8ki8KLyw+swRDB6BCITyWLww+s0AiIRyaLxohfJ8HqCItYKIvLi1Asi8LB6BiIRyiLwsHoEIhHKYvCwegIiEcqi8IPrMEYiFcrwegYiE8si8KLyw+swRDB6BCLw4hPLQ+s0AjB6giIRy6LxohfL413OGjIAAAAagCLWDCLy4tQNIvCwegYiEcwi8LB6BCIRzGLwsHoCIhHMovCD6zBGIhXM8HoGIhPNIvCi8sPrMEQwegQiE81i8MPrNAIiEc2iF83i30IweoIV4tXPIvCi184i8vB6BiIBovCwegQiEYBi8LB6AiIRgKLwg+swRiIVgPB6BiITgSLwovLD6zBEMHoEIvDiE4FD6zQCIhGBsHqCIheB+jlCgAAg8QMX15bi+VdwggAzMzMzMzMzMzMVYvs6NjU//+5MIaKAIHpAECKAAPBi00IUVD/dRCNgcQAAAD/dQxogAAAAFCNQUBQ6Hvk//9dwgwAzMzMzMzMzFWL7FaLdQj/dQyLDo1GCFD/dgSLQQT/0ItWLItGMAPWSF6ARAIIAXUTDx+AAAAAAIXAdAhIgEQCCAF09F3CCABVi+xTi10MVleLfQgPtkMYmYvIi/IPpM4ID7ZDGcHhCJkLyAvyD6TOCA+2QxrB4QiZC8gL8g+kzggPtkMbweEImQvIC/IPtkMcD6TOCJnB4QgL8gvID7ZDHQ+kzgiZweEIC/ILyA+2Qx4PpM4ImcHhCAvyC8gPtkMfD6TOCJnB" & _
                                                    "4QgL8gvIiXcEiQ8PtkMQmYvIi/IPtkMRD6TOCJnB4QgL8gvID7ZDEg+kzgiZweEIC/ILyA+2QxMPpM4ImcHhCAvyC8gPtkMUD6TOCJnB4QgLyAvyD6TOCA+2QxXB4QiZC8gL8g+kzggPtkMWweEImQvIC/IPpM4ID7ZDF8HhCJkLyAvyiU8IiXcMD7ZDCJmLyIvyD6TOCA+2QwnB4QiZC8gL8g+2QwoPpM4ImcHhCAvyC8gPtkMLD6TOCJnB4QgL8gvID7ZDDA+kzgiZweEIC/ILyA+2Qw0PpM4ImcHhCAvyC8gPtkMOD6TOCJnB4QgL8gvID7ZDDw+kzgiZweEIC/ILyIl3FIlPEA+2A5mLyIvyD7ZDAQ+kzgiZweEIC/ILyA+2QwIPpM4IweEImQvIC/IPtkMDD6TOCJnB4QgL8gvID7ZDBA+kzgiZweEIC/ILyA+2QwUPpM4ImcHhCAvyC8gPtkMGD6TOCJnB4QgL8gvID7ZDBw+kzgiZweEIC8gL8ol3HIlPGF9eW13CCADMzMxVi+yD7GCNReD/dQxQ6N79//+NReBQ6OUgAACFwHQIM8CL5V3CCACNReBQ6ADS//+D6IBQ6FcgAACD+AF0E+jt0f//g+iAUI1F4FBQ6I8rAABqAI1F4FDo1NH//4PAQFCNRaBQ6IfT//+NRaBQ6E7T//+FwHWpikXAi00IJAEEAogBjUWgUI1BAVDoEQAAALgBAAAAi+VdwggAzMzMzMzMVYvsVot1CLEoV4t9DA+2RweIRhgPtkcGiEYZiweLVwToy9f//4hGGrEgiweLVwTovNf//4hGG4sPi0cED6zBGIhOHIsPwegYi0cED6zBEIhOHYsPwegQi0cED6zBCIhOHrEowegID7YHiEYfD" & _
                                                    "7ZHD4hGEA+2Rw6IRhGLRwiLVwzoa9f//4hGErEgi0cIi1cM6FvX//+IRhOLTwiLRwwPrMEYiE4Ui08IwegYi0cMD6zBEIhOFYtPCMHoEItHDA+swQiIThaxKMHoCA+2RwiIRhcPtkcXiEYID7ZHFohGCYtHEItXFOgG1///iEYKsSCLRxCLVxTo9tb//4hGC4tPEItHFA+swRiITgyLTxDB6BiLRxQPrMEQiE4Ni08QwegQi0cUD6zBCIhODrEowegID7ZHEIhGDw+2Rx+IBg+2Rx6IRgGLRxiLVxzootb//4hGArEgi0cYi1cc6JLW//+IRgOLTxiLRxwPrMEYwegYiE4Ei08Yi0ccD6zBEMHoEIhOBYtPGItHHA+swQjB6AiITgYPtkcYX4hGB15dwggAzMxVi+yD7CBTVot1CA9XwFeLfQzHReADAAAAx0XkAAAAAA8RReiNRwFmD9ZF+FBW6H37//9WjV4gU+jjJAAA6K7P//9QjUXgUFNT6AIlAABWU1PomiQAAOiVz///UOiPz///g8AgUFNT6AQiAABT6C4GAACKBzP2iwskAQ+2wIPhAZk7yHUEO/J0DVPoYc///1BT6AopAABfXluL5V3CCADMVYvsgeygAAAAjYVg/////3UIUOhI/////3UMjUXgUOjs+v//agCNReBQjYVg////UI1FoFDo1tD//41FoFD/dRDoev3//41FoFDokdD///fYG8BAi+VdwgwAzMzMzMzMVYvsg+xAjUXAVv91CFDo7f7//4t1DI1FwFCNRgHGBgRQ6Dr9//+NReBQjUYhUOgt/f//uAEAAABei+VdwggAzFWL7ItNCIvBwegHgeF/f3//JQEBAQEDyWvAGzPBXcIEAMzMzMzMzMzMzM" & _
                                                    "zMzMzMzFWL7OiYzv//uaByigCB6QBAigADwYtNCFFQ/3UQjUEw/3UMahBQjUEgUOhB3v//XcIMAMzMzMzMzMzMzMzMzMxVi+yLTQiLRRABQTiDUTwAiUUQiU0IXemk////zMzMzFWL7FaLdQiDfkgBdQ1W6C0AAADHRkgCAAAAi0UQAUZAUP91DINWRABW6HL///9eXcIMAMzMzMzMzMzMzMzMzMxVi+xWi3UIi04whcl0KbgQAAAAK8FQjUYgA8FqAFDozQMAAIPEDI1GIFBW6BAAAADHRjAAAAAAXl3CBADMzMzMVYvsg+wQjUXwVldQ/3UM6Mzu//+LdQiNRfCNfhBXV1DoC+7//1dWV+hT7///X16L5V3CCADMzMzMzMzMzMzMzFWL7IPsFFNWi3UIi0ZIg/gBdAWD+AJ1DVboYv///8dGSAAAAACLXjiLVjwPpNoDagiLwsHjA8HoGIvLiEXsi8LB6BCIRe2LwsHoCIhF7g+2wohF74vCD6zBGIlV/MHoGIhN8IvCi8uIXfMPrMEQwegQi8OITfEPrNAIiEXyjUXsUMHqCFboVv7//4teQItWRA+k2gNqCIvCweMDwegYi8uIReyLwsHoEIhF7YvCwegIiEXuD7bCiEXvi8IPrMEYiVX8wegYiE3wi8KLy4hd8w+swRDB6BCLw4hN8Q+s0AiIRfKNRexQweoIVujx/f///3UMjUYQUOjV7v//XluL5V3CCADMzMzMzMzMzMzMzMzMVYvsVot1CGpQagBW6E8CAACDxAxW/3UM6HPt///HRkgBAAAAXl3CCADMzMzMzMzMVYvsgeyAAAAAuSAAAABTi10MVleL8419gPOlvv0AAACNRYBQUOh2FgAAg/4CdBCD/gR0C1ONRYB" & _
                                                    "QUOgxAwAAg+4BedyLfQiNdYC5IAAAAPOlX15bi+VdwggAzMzMzMzMVYvsU1aLdQhXVugB/f//i9hT6Pn8//+L0FLo8fz//4v4M/6L94vHM8PBzwgz8sHACIvOwckQM8EzxzPGXzPDM0UIXltdwgQAzMzMzMzMzMxVi+xWi3UI/zboov////92BIkG6Jj/////dgiJRgTojf////92DIlGCOiC////iUYMXl3CBADMzMzMzMzMzMzMVYvsU4tdCFZXD7Z7Bw+2QwIPtnMLD7ZTD8HnCAv4D7ZLAw+2Qw3B5wgL+MHmCA+2QwjB5wgL+MHiCA+2QwYL8MHhCA+2QwHB5ggL8A+2QwzB5ggL8A+2QwoL0A+2QwXB4ggL0A+2A8HiCAvQD7ZDDgvIiVMMD7ZDCcHhCAvIiXMID7ZDBIl7BMHhCF8LyF6JC1tdwgQAzMzMzMzMzMzMzFWL7Fboh8r//4t1CAWTBQAAUP826CcWAACJBuhwyv//BZMFAABQ/3YE6BIWAACJRgToWsr//wWTBQAAUP92COj8FQAAiUYI6ETK//8FkwUAAFD/dgzo5hUAAIlGDF5dwgQAzMzMzMzMzMzMzMzMzMxVi+yLRQiL0FaLdRCF9nQVV4t9DCv4igwXjVIBiEr/g+4BdfJfXl3DzMzMzMzMzMxVi+yLTRCFyXQfD7ZFDFaL8WnAAQEBAVeLfQjB6QLzq4vOg+ED86pfXotFCF3DzMxVi+xWi3UIVugD+///i9CLzjPWwckQwcIIwc4IM9Ez1jPCXl3CBADMzMzMzMzMzMxVi+xWi3UI/zbowv////92BIkG6Lj/////dgiJRgTorf////92DIlGCOii////iUYMXl3CBADMzMzMzMzMzMzMVYvsg+xA" & _
                                                    "Vg9XwMdFwAEAAABXjUXAx0XEAAAAAFAPEUXIx0XgAQAAAGYP1kXYx0XkAAAAAA8RRehmD9ZF+OgOyf//UI1FwFDo1BUAAI1FwFDo6x8AAIt9CI1w/4P+AXYpjUXgUFDoFh4AAFaNRcBQ6OwjAAALwnQLV41F4FBQ6M0dAABOg/4Bd9eNReBQV+iNIAAAX16L5V3CBADMzMzMzFWL7IHsAAEAAItFDA9XwFNWV7k8AAAAZg8ThQD///+NtQD////HRfwQAAAAjb0I////86WLTRCNnQj///+DwRCL0yvCiU34iUUMZg8fRAAAi/nHRRAEAAAAi/MPH0QAAP90GAT/NBj/d/T/d/DoTs7//wFG+ItFDBFW/P90GAT/NBj/d/z/d/joM87//wEGi0UMEVYE/3QYBP80GP93BP836BrO//8BRgiLRQwRVgz/dBgE/zQY/3cM/3cI6P/N//8BRhCNfyCLRQwRVhSNdiCDbRABdYqLTfiDwwiDbfwBD4Vq////M/ZqAGom/3T1hP909YDox83//wGE9QD///9qABGU9QT///9qJv909Yz/dPWI6KjN//8BhPUI////agARlPUM////aib/dPWU/3T1kOiJzf//AYT1EP///2oAEZT1FP///2om/3T1nP909Zjoas3//wGE9Rj///9qABGU9Rz///9qJv909aT/dPWg6EvN//8BhPUg////EZT1JP///4PGBYP+Dw+CWf///4tdCI21AP///7kgAAAAi/vzpVPoKdD//1PoI9D//19eW4vlXcIMAMzMzMzMzMzMzMxVi+yD7BBTVot1DFeLfRhqAFZqAP91FOjkzP//agBWagBXiUXwi9ro1Mz//2oA/3UQiUX0i/JqAFfowsz//2oA/3UQi" & _
                                                    "UX8agD/dRSJVfjorcz//4v4i0X0A/uD0gAD+BPWO9Z3DnIEO/hzCINF/ACDVfgBi0UIM8kLTfCJCDPJA1X8iXgEE034X16JUAiJSAxbi+VdwhQAzMzMzMzMzMzMVYvsgewIAQAAjYV4////U1ZX/3UMUOilCQAAjYV4////UOhJz///jYV4////UOg9z///jYV4////UOgxz///jb34/v//uwIAAABmDx9EAACLjXj///+LhXz///+B6e3/AACJjfj+//+D2ACJhfz+//+4CAAAAGZmDx+EAAAAAACLdAf4i0wH/IuUBXj///+JdfgPrM4Qi4wFfP///4PmAcdEB/wAAAAAK9aD2QCB6v//AACJlAX4/v//g9kAiYwF/P7//w+3TfiJTAf4g8AIg/h4cqyLjWj///+LhWz///+LVfAPrMEQD7eFaP///4PhAYmFaP///yvRx4Vs////AAAAAItN9LgBAAAAg9kAger/fwAAiZVw////g9kAiY10////D6zKEIPiAcH5ECvCUI2F+P7//1CNhXj///9Q6I0HAACD6wEPhQT///+LdQgz0oqE1Xj///+LjNV4////iARWi4TVfP///w+swQiITFYBQsH4CIP6EHLXX15bi+VdwggAzMzMzMzMzMzMzMzMzFWL7ItFCDPSVleLfQwr+I1yEYsMB41ABANI/APRD7bKweoIiUj8g+4BdedfXl3CCADMzMzMzMzMzMzMzMzMzMxVi+xW/3UMi3UIVuiw////jUZEUFbotgEAAF5dwggAzFWL7IPsRFNWi3UIVw8QBotGQIlF/A8RRbwPEEYQDxFFzA8QRiAPEUXcDxBGMA8RRezoKsT//wVEBAAAUI1FvFDoW////4tF/I19vPfQjVXMJY" & _
                                                    "AAAAAr/rkCAAAAjVj/99DB6B/B6x8j2PfbK9aLw/fQiUUIZg9uw2YPcNAAZg9uwIvGZg9w2AAPH4QAAAAAAI1AIA8QQOAPEEwH4GYP28JmD9vLZg/ryA8RSOAPEEDwDxBMAuBmD9vCZg/by2YP68gPEUjwg+kBdcaNVkCNcQGLDDqNUgQjTQiLwyNC/AvIiUr8g+4BdehfXluL5V3CBADMzMzMzMzMzMzMzMzMzMxVi+yD7ESNRbxWakRqAFDoXPn//4t1CIPEDDPAi5aoAAAAhdJ0G2ZmDx+EAAAAAAAPtowGmAAAAIlMhbxAO8Jy741FvMdElbwBAAAAUFbojf7//16L5V3CBADMzMzMzMxVi+xWi3UIM8Az0g8fRAAAAwSWD7bIiQyWQsHoCIP6EHzuA0ZAi8jB6AKD4QMz0olOQI0MgAMMlg+2wYkElkLB6QiD+hB87gFOQF5dwgQAzFWL7IPsVItFDI1NrFNWi3UIM9srwcdF+BAAAABXiUXwM9Iz/zPAiVUIiVX8hdt4UY1LAYP5Anwwi03wjVWsjQyZA9GLDIaNUvgPr0oIAU0Ii0yGBIPAAg+vSgQBTfyNS/87wX7ei1UIO8N/Dot9DIvLK8iLPI8PrzyGi0X8A8ID+I1DATPSiVUIi8iJVfyJRfSD+BF9coN9+AJ8Q4tVDIvDK8GNFIKDwkAPH4AAAAAAiwSOjVL4D69CDI0EgMHgBgFFCItEjgSDwQIPr0IIjQSAweAGAUX8g/kQfNSLVQiD+RF9GotVDIvDK8GLRIJED68EjotVCI0EgMHgBgP4i0X8A8ID+ItF9ItN+EmJfJ2siU34i9iD+f8PjwL///+NRaxQ6In+//8PEEWsi0XsXw8RBg8QRbwPEUYQDxBFzA8" & _
                                                    "RRiAPEEXcDxFGMIlGQF5bi+VdwggAzMzMzMzMzMzMzMxVi+yLVQyD7EQzwA8fRAAAD7YMEIlMhbxAg/gQfPKNRbzHRfwBAAAAUP91COif/P//i+VdwggAzMzMzMzMzMzMVYvsgex8AQAAU1ZXagz/dQyNReDGRdwAD1fAx0XlAAAAAFBmD9ZF3WbHRekAAMZF6wDoufb//4PEDMZFvACNRdzHRdUAAAAAD1fAZsdF2QAADxFFvWoEUGog/3UIjYUw////Zg/WRc1QxkXbAOi+2P//aiCNRbxQUI2FMP///1DoC9L//41FzFCNRbxQjYWE/v//UOj34///D1fADxFFvIpFvGogjUW8UFCNhTD///9QDxFFzOjW0f//i3UUD1fAVv91EA8RRbyKRbyNhYT+///GRewAUA8RRczHRfUAAAAAZg/WRe1mx0X5AADGRfsA6Gvk//+LxvfYg+APUI1F7FCNhYT+//9Q6FPk//+DfSQBi30gi10cU3UUV/91GI2FMP///1DoZtH//1NX6wP/dRiNhYT+//9Q6CPk//+Lw/fYg+APUI1F7FCNhYT+//9Q6Avk//8z0ohd9IvGiVXoiEXsi8iLwg+swQhqEMHoCIhN7YvCi84PrMEQwegQiE3ui8KLzg+swRjB6BgPtsKIRfCLwsHoCIhF8YvCwegQiEXyweoYiE3vi8uIVfMz0ovCiVXoD6zBCMHoCIhN9YvCi8sPrMEQwegQiE32i8KLyw+swRjB6BgPtsKIRfiLwsHoCIhF+YvCwegQiEX6jUXsUI2FhP7//8HqGFCITfeIVfvoW+P//4N9JAF1M/91KI2FhP7//1Do9uH//2p8jYUw////agBQ6Pb0//+KhTD///+DxAwzwF9eW4vlXcIk" & _
                                                    "AI1FrFCNhYT+//9Q6MLh//+LdSiNTayLwTLbuhAAAAAr8JCKBA6NSQEyQf8K2IPqAXXwi0UchNt1P1BX/3UYjYUw////UOgI0P//anyNhTD///9qAFDoiPT//4qFMP///4PEDA9XwA8RRayKRaxfXjPAW4vlXcIkAIXAdA5QagBX6F30//+KB4PEDGp8jYUw////agBQ6Ej0//+KhTD///+DxAwPV8APEUWsikWsX164AQAAAFuL5V3CJADMzMzMzMzMVYvsVleLfQgPtgeZi8iL8g+2RwEPpM4ImcHhCAvyC8gPtkcCD6TOCJnB4QgL8gvID7ZHAw+kzgiZweEIC/ILyA+2RwQPpM4ImcHhCAvyC8gPtkcFD6TOCJnB4QgL8gvID7ZHBg+kzgiZweEIC/ILyA+2RwcPpM4ImcHhCAvBC9ZfXl3CBADMzMzMzMzMzMzMVYvsg+wIi0UQSPfQmVOLXQiJRfiLRQyJVfzzD35d+I1LeFYz9mYPbNuNUHg7wXdLO9NyRyvYx0UQEAAAAFdmkIs8GI1ACIt0GPyLSPiLUPwzzyNN+DPWI1X8M/kz8ol8GPiJdBj8MUj4MVD8g20QAXXOX15bi+VdwgwAi9ONSBAr0A8QDPONSSAPEFHQZg/v0WYP29MPKMJmD+/BDxEE84PGBA8QQdBmD+/QDxFR0A8QTArgDxBR4GYP79FmD9vTDyjCZg/vwQ8RRArgDxBB4GYP78IPEUHgg/4QcqVeW4vlXcIMAMzMzMzMzMzMzMzMVYvsi1UMi0UIK9BWvhAAAACLDAKNQAiJSPiLTAL8iUj8g+4BdeteXcIIAMzMzMzMVYvsi0UQVleD+BB0P4P4IHQG/xXUsIoAi3UMi30IahBWV+gZ8v//ahCNR" & _
                                                    "hBQjUcQUOgK8v//g8QY6CK8//8FMQQAAIlHMF9eXcIMAIt1DIt9CGoQVlfo5fH//2oQjUcQVlDo2fH//4PEGOjxu///BSAEAACJRzBfXl3CDADMzMxVi+yD7GyLRQiNVZRTVrugAAAAM/aLSASJTfiLSAiJTfSLSAyJTeiLSBCJTfyLSBSJTfCLSBiJTeyLTQyDwQKJddxXizgr04tAHIl94IlF5IlN2IldDIlV1A8fgAAAAACD/hBzKQ+2cf4PtkH/weYIC/APtgHB5ggL8A+2QQHB5ggL8IPBBIk0GolN2OtUjV4Bg+YPjUP9g+APjX2UjTy3i0yFlIvDg+APi/HBxg+LVIWUi8HBwA0z8MHpCjPxi8KLysHIB8HBDjPIweoDjUP4M8qLXQyD4A8D8QN0hZQDN4k36Pm6//+LffyL18HKC4vPwcEHM9GLz8HJBvfXI33sM9GLDBiDwwSLRfADyiNF/APOi3XgM/iL1oldDMHKDYvGwcAKA/kDfeQz0IvGwcgCM9CLRfiLyCPGM84jTfQzyItF7IlF5APRi0Xwi034iUXsi0X8iUXwi0XoA8eJdfiLddwD+otV1EaJRfyLRfSJTfSLTdiJReiJfeCJddyB+6ABAAAPgtf+//+LRQiLTfiLVfwBSASLTfQBSAgBUBABOItN6ItV8AFIDAFQFItV7ItN5AFQGAFIHP9AYF9eW4vlXcIIAMzMzMzMzMzMzMzMzFWL7IHs4AAAAFNWi3UIu6ABAABXiV24iwaJReyLRgSJRfCLRgyLfgiJReCLRhCJRdSLRhSJRdCLRhiJRbSLRhyJRbCLRiCJReiLRiSJRfSLRiiJRcyLRiyJRciLRjCJRcSLRjSJRcCLRjiJRayLRjyLdQyJfdiNvS" & _
                                                    "D///+JRagzwCv7iUXciX2gDx+AAAAAAIP4EHMfVuhl+///i8iDxgiLwolNDIlF5IkMH4lEHwTpEwEAAI1QAcdFDAAAAACNQv2D4A+LjMUg////i4TFJP///4lF+IvCg+APiU38jY0g////i5TFIP///4v6i5zFJP///4tF3IPgD4lVvMHnGI0EwYvLiUWki8IPrMgICUUMi0W8wekIC/mLyw+syAGJfeSL+tHpM9IL0MHnHzFVDAv5i0W8i03kD6zYBzPPMUUMi0X8wesHM8sz24lN5ItN+IvRD6TBA8HqHcHgAwvZi034C9CLRfyL+A+syBOJVbwz0gvQwekTi0W8M8LB5w2LVfwL+YtN+DPfD6zKBjPCwekGi1UMM9mLTeQD0ItF3BPLg8D5g+APA5TFIP///xOMxST///+LRaQDEIlVDBNIBIkQiU3kiUgE6ES4//+LVfQz/4tN6IvaD6TKF8HrCQv6weEXi1X0C9mLTeiJXfyL2Q+s0RKJffgz/wv5weoSMX38M/+LTejB4w4L2otV9DFd+IvZD6zRDsHjEgv5weoOMX38C9qLTfiLVbgzy4td/It96PfXAxwQE0wQBCN9xItV9ItFyPfSI0X0I1XAM9CJTfiLTcwjTeiLRfgz+YtN8APfE8IDXQwTReQDXayJXfwTRagz24lF+ItF7IvQD6zIHMHiBMHpHAvYi0XsC9GLTfCL+Q+kwR6JVQwz0sHvAgvRweAeC/gz3zFVDDPSi03wi/mLRewPpMEZwe8HC9HB4BkxVQwL+ItN2DPfi1Xgi/kzfewjfdQjTewzVfAz+SNV0ItF4CNF8ItNxDPQi0UMA9+LffgTwolNrItNwItV/ANVtIlNqBN9sItNzANd/IlNxItNyIlNwIt"
Private Const STR_THUNK3                As String = "N6IlNzItN9Il99It91Il9tIt90Il9sIt92Il91It94Il90It97IlNyIvIE034i0XciV3sQItduIl92IPDCIt98Il94It9oIlV6IlN8IlF3IlduIH7IAQAAA+CG/3//4t1CItF7It92AEGi0XgEU4Ei8oBfgiLfbQRRgyLRdQBRhCLRdARRhQBfhiLRbARRhwBTiCLRfQRRiSLRcwBRiiLRcgRRiyLRcQBRjCLRcARRjSLTawBTjiLTagRTjz/hsAAAABfXluL5V3CCADMzMzMzMzMzMzMzMzMzFWL7FOLXQhWVw+2ewcPtkMKD7ZzCw+2Uw/B5wgL+A+2SwMPtkMNwecIC/jB5ggPtgPB5wgL+MHiCA+2Qw4L8MHhCA+2QwHB5ggL8A+2QwTB5ggL8A+2QwIL0A+2QwXB4ggL0A+2QwjB4ggL0A+2QwYLyIl7BA+2QwnB4QgLyIlzCA+2QwzB4QhfC8iJUwxeiQtbXcIEAMzMzMzMzMzMzMxVi+yLRQxQUP91COjA7P//XcIIAMzMzMzMzMzMzMzMzFWL7ItFEFNWi3UIjUh4V4t9DI1WeDvxdwQ70HMLjU94O/F3MDvXciwr+LsQAAAAK/CLFDgrEItMOAQbSASNQAiJVDD4iUww/IPrAXXkX15bXcIMAIvXjUgQi94r0CvYK/64BAAAAI12II1JIA8QQdAPEEw34GYP+8gPEU7gDxBMCuAPEEHgZg/7yA8RTAvgg+gBddJfXltdwgwAzMzMzMxVi+xW6Le0//+LdQgFiAQAAFD/NuhXAAAAiQbooLT//wWIBAAAUP92BOhCAAAAiUYE6Iq0//8FiAQAAFD/dgjoLAAAAIlGCOh0tP//BYgEAABQ/3YM6BYAAACJRgxeXcIEAMzM" & _
                                                    "zMzMzMzMzMzMzMzMVYvsi1UMU4tdCIvDwegYi8tWwekID7bJD7Y0EIvDwegQD7bAD7YMEcHmCA+2BBALxsHgCAvBD7bLweAIXlsPtgwRC8FdwggAzMzMzMzMzMxVi+yLTQxTi10IVoPDEMdFDAQAAABXg8EDDx+AAAAAAA+2Qf6NWyCZjUkIi/CL+g+2QfUPpPcImcHmCAPwiXPQE/qJe9QPtkH3mYvwi/oPtkH4mQ+kwgjB4AgD8Ilz2BP6iXvcD7ZB+pmL8Iv6D7ZB+Q+k9wiZweYIA/CJc+AT+ol75A+2QfyZi/CL+g+2QfsPpPcImcHmCAPwiXPoE/qDbQwBiXvsD4V0////i00IX15bgWF4/38AAMdBfAAAAABdwggAzMzMzMzMzMzMzMzMVYvsg+wIU4tdDA9XwFZXi30QixOL8otDBIvIZg8TRfgDNxNPBDvydQY7yHUE6xg7yHcPcgQ78nMJuAEAAAAz0usLZg8TRfiLRfiLVfyLfQiJTwSLTRCJN4txCANzCItJDBNLDAPwE8o7cwh1BTtLDHQgO0sMdxByBTtzCHMJuAEAAAAz0usLZg8TRfiLVfyLRfiJTwyLTRCJdwiLcRADcxCLSRQTSxQD8BPKO3MQdQU7SxR0IDtLFHcQcgU7cxBzCbgBAAAAM9LrC2YPE0X4i1X8i0X4iU8UiXcQi0sYi1sciU0Mi00Qi3EYA3UMi0kcE8sD8BPKO3UMdQQ7y3QsO8t3HXIFO3UMcxaJdxi4AQAAAIlPHDPSX15bi+VdwgwAZg8TRfiLVfyLRfiJdxiJTxxfXluL5V3CDADMzMzMzMxVi+yLRQjHAAAAAADHQAQAAAAAx0AIAAAAAMdADAAAAADHQBAAAAAAx0AUAAAAAMdAG" & _
                                                    "AAAAADHQBwAAAAAXcIEAMzMzMzMzMzMzMzMzMzMzFWL7ItNDLoDAAAAU4tdCFYr2Y1BGFeJXQgPH4AAAAAAizQDi1wDBIt4BIsIO993LnIiO/F3KDvfchp3BDvxchSLXQiD6AiD6gF51V9eM8BbXcIIAF9eg8j/W13CCABfXrgBAAAAW13CCADMzMzMzMxVi+yLVQgzwA8fhAAAAAAAiwzCC0zCBHUPQIP4BHLxuAEAAABdwgQAM8BdwgQAzMxVi+yD7BBTi10QuUAAAABWi3UIK8tXi30MZg9uw4lNEIsHi1cEiUX4iVX88w9+TfhmD/PIZg/WDugjt///i00QiUXwi0cIiVX0i1cMiUX4iVX88w9+TfhmD27DZg/zyPMPfkXwZg/ryGYP1k4I6O62//+LTRCJRfCLRxCJVfSLVxSJRfiJVfzzD35N+GYPbsNmD/PI8w9+RfBmD+vIZg/WThDoubb//4tNEIlF8ItHGIlV9ItXHIlF+IlV/PMPfk34Zg9uw2YP88jzD35F8GYP68hmD9ZOGOiEtv//X15bi+VdwgwAzMzMzMzMzMzMzMxVi+yD7ChTi10IVleLfQxXU+jKBwAAi0csD1fAiUXki0cwiUXoi0c0iUXsi0c4iUXwi0c8iUX0jUXYagFQUGYPE0XYx0XgAAAAAOjB/v//i/CNRdhQU1PohPz//4tPOAPwi0cwi1c8iUXkM8ALRzSJReiNRdhqAVBQx0XgAAAAAIlN7IlV8MdF9AAAAADofv7//wPwjUXYUFNT6EH8//8D8MdF5AAAAACLRyAPV8CJRdiLRySJRdyLRyiJReCLRziJRfCLRzyJRfSNRdhQU1NmDxNF6OgH/P//i08kA/AzwIlN2AtHKIlF3ItHMItXNI" & _
                                                    "vKiUX4M8ALRyyJReCLRziJReiLRzyJRewzwAtHIIlF9I1F2FBTU4lN5IlV8Oi/+///i08sA/CLVzQzwAtHMA9XwIlF3ItHIIlF8I1F2IlN2DPJC08oUFNTiVXgx0XkAAAAAGYPE0XoiU306GEIAACLVyQr8ItHMA9XwIlF2LEgi0c0iUXci0c4iUXgi0c8iUXki0cgZg8TRejo4rT//wtXLIlF8I1F2FBTU4lV9OgeCAAAi1UMK/CLTzQzwAtHOItfJIlF3DPAC0c8iU3Yi08gM/+JReCLQiiLUiyJTeSxIOh7tP//C9jHRfAAAAAAiV3oC/qLXQyJfeyLfQiLQzCJRfSNRdhQV1fowwcAACvwx0XgAAAAAItDOIlF2ItDPIlF3ItDJIlF5ItDKIlF6ItDLIlF7ItDNIlF9I1F2FBXV8dF8AAAAADohAcAACvweSDoy63//1BXV+iT+v//A/B4719eW4vlXcIIAGYPH0QAAIX2dRFX6Kat//9Q6AD8//+D+AF03OiWrf//UFdX6D4HAAAr8OvazMzMzMzMzMzMzFWL7Fb/dRCLdQj/dQxW6D36//8LwnUN/3UUVujA+///hcB4Cv91FFZW6AIHAABeXcIQAMzMzMzMzMzMzMzMzMxVi+yB7IgAAABWi3UMVuj9+///hcB0D/91COgx+///XovlXcIMAFdWjYV4////UOjcBAAAi30QjUWYV1DozwQAAI1F2FDoBvv//41FuMdF2AEAAABQx0XcAAAAAOjv+v//jUWYUI2FeP///1DoL/v//4vQhdIPhLABAABTDx9AAIuNeP///w9XwIPhAWYPE0X4g8kAdS+NhXj///9Q6A4EAACLRdiD4AGDyAAPhLYAAABXjUXYUFDoVPn//4v" & _
                                                    "wi9rpqAAAAItFmIPgAYPIAHUsjUWYUOjXAwAAi0W4g+ABg8gAD4QIAQAAV41FuFBQ6B35//+L8Iva6foAAACF0g+OjAAAAI1FmFCNhXj///9QUOjbBQAAjYV4////UOiPAwAAjUW4UI1F2FDocvr//4XAeQtXjUXYUFDo0/j//41FuFCNRdhQUOilBQAAi0XYg+ABg8gAdBFXjUXYUFDor/j//4vwi9rrBotd/It1+I1F2FDoOgMAAAvzD4SSAAAAi0XwgU30AAAAgIlF8OmAAAAAjYV4////UI1FmFBQ6E8FAACNRZhQ6AYDAACNRdhQjUW4UOjp+f//hcB5C1eNRbhQUOhK+P//jUXYUI1FuFBQ6BwFAACLRbiD4AGDyAB0EVeNRbhQUOgm+P//i/CL2usGi138i3X4jUW4UOixAgAAC/N0DYtF0IFN1AAAAICJRdCNRZhQjYV4////UOiA+f//i9CF0g+FVv7//1uNRdhQ/3UI6NkCAABfXovlXcIMAMxVi+yD7ECNRcD/dRD/dQxQ6HsAAACNRcBQ/3UI6M/6//+L5V3CDADMzMzMzMzMzMxVi+yD7ECNRcD/dQxQ6M4CAACNRcBQ/3UI6KL6//+L5V3CCADMzMzMzMzMzMzMzMxVi+xW/3UQi3UI/3UMVug9BAAAC8J0Cv91FFZW6E/3//9eXcIQAMzMzMzMzMzMzMxVi+yD7GBTD1fAVmYPE0XYi0XcV2YPE0XQM/+LXdSJRfwz9o1H/YP/BA9XwGYPE0X0i1X0D0PwO/cPh9IAAACLTRCLxw8QRdArxg8RRcCNHMGLRfiJRfCJVfhmDx9EAACD/gQPg6MAAAD/cwSLRQz/M/908AT/NPCNRbBQ6P/i//+D7BCLzIPsEA8Q" & _
                                                    "AA8QCIvEDxEBDxBFwA8RTeAPEQCNRaBQ6Oiw//9mD3PZDA8QEGYPfsgPKMJmD3PYDGYPfsEPEVXAiU38DxFV0DvIdxNyCItF2DtF6HMJuAEAAAAzyesOD1fAZg8TReiLTeyLReiLVfgD0ItF8IlV+BPBRoPrCIlF8Dv3D4ZU////i13U6wOLRfiLTQiLddCJNPmL8YvKi9CJVdyJXP4ER4t12Itd/Il10Ild1IlN2IlV/IP/Bw+C2/7//4tFCF+JcDheiVg8W4vlXcIMAMzMzMzMzMzMVYvsVleLfQhX6EIAAACL8IX2dQZfXl3CBACLVPf4i8qLRPf8M/8LyHQTZg8fRAAAD6zCAUfR6IvKC8h188HmBo1GwAPHX15dwgQAzMzMzMxVi+yLVQi4AwAAAA8fRAAAiwzCC0zCBHUFg+gBefJAXcIEAMzMzMzMzMzMzMzMzMxVi+yD7AiLRQgPV8BTi9hmDxNF+IPAIDvDdjiLTfhWV4t9/IlNCItw+IPoCIvOi1AED6zRAQtNCNHqC9eJCIv+iVAEwecfx0UIAAAAADvDd9VfXluL5V3CBADMzMzMzMxVi+yLVQyLTQiLAokBi0IEiUEEi0IIiUEIi0IMiUEMi0IQiUEQi0IUiUEUi0IYiUEYi0IciUEcXcIIAMzMzMzMVYvsg+xgUw9XwDPJVmYPE0XYi0XcV2YPE0XQi33UiU3oiUXwM/aNQf2D+QQPV8BmDxNF+Itd/A9D8DvxD4cZAQAAi1UMi8EPEEXQK8aJXfQPEUXAjQTCi1X4iUXsiVX8i/kr/jv3D4fqAAAA/3AE/zCLRQz/dPAE/zTwjUWwUOh84P//DxAADxFF0Dv3c0OLTdyLwYtV1Iv6wegfAUX8i0XYg9MAwe8fD" & _
                                                    "6TBAYld9DPbA8AL2Qv4iV3ci0XQD6TCAYl92APAiVXUiUXQDxBF0OsGi13ci33Yg+wQi8SD7BAPEQCLxA8QRcAPEQCNRaBQ6Buu//8PEAgPKMFmD3PYDGYPfsAPEU3AiUXwDxFN0DvDdxByBTl92HMJuAEAAAAzyesOD1fAZg8TReCLTeSLReCLVfyLXfQD0ItF7BPZiVX8i03oRoPoCIld9IlF7DvxD4YK////i33U6wOLVfiLdQiLRdCJBM6LRdiJfM4EQYt98IlV2IvTiUXQiX3UiVXwiVXciU3og/kHD4KV/v//iX48X4lGOF5bi+VdwggAzMxVi+yD7AxTi10MD1fAVleLfRCLE4vyi0MEi8hmDxNF9Cs3G08EO/J1BjvIdQTrGDvIcg93BDvydgm4AQAAADPS6wtmDxNF9ItF9ItV+It9CIlPBItNEIk3i3MIiXX4K3EIi0sMi10QG0sMK/CLXQwbyjt1+HUFO0sMdCA7SwxyEHcFO3MIdgm4AQAAADPS6wtmDxNF9ItV+ItF9IlPDItNEIl3CItzEIl1/CtxEItLFItdEBtLFCvwi10MG8o7dfx1BTtLFHQgO0sUchB3BTtzEHYJuAEAAAAz0usLZg8TRfSLVfiLRfSJTxSJdxCLSxiL8Yt9EItbHIlNDItNECtxGIvLG08cK/CLfQgbyjt1DHUEO8t0LDvLch13BTt1DHYWiXcYuAEAAACJTxwz0l9eW4vlXcIMAGYPE0X0i1X4i0X0iXcYiU8cX15bi+VdwgwAzMzMzMzMzMzMzMzMzMzMVYvsi00IM9JWV4t9DDP2i8eD4D8Pq8aD+CAPQ9Yz8oP4QA9D1sHvBiM0+SNU+QSLxl9eXcIIAMzMzMzMzMzMzFWL7ItVFI" & _
                                                    "PsEDPJhdIPhMIAAABTi10QVot1CFeLfQyD+iAPgosAAACNQ/8DwjvwdwmNRv8DwjvDc3mNR/8DwjvwdwmNRv8DwjvHc2eLwovXK9OD4OCJVfyL1ivTiUXwiVX4i8OLXfiL14t9/CvWiVX0jVYQDxAAi3X0g8EgjUAgjVIgDxBMB+BmD+/IDxFMA+APEEwW4It1CA8QQPBmD+/IDxFK4DtN8HLKi1UUi30Mi10QO8pzGyv7jQQZK/Mr0YoMOI1AATJI/4hMMP+D6gF17l9eW4vlXcIQAAAA" ' 23661, 19.4.2020 19:52:54
Private Const STR_LIBSODIUM_SHA384_STATE As String = "2J4FwV2du8sH1Xw2KimaYhfdcDBaAVmROVkO99jsLxUxC8D/ZyYzZxEVWGiHSrSOp4/5ZA0uDNukT/q+HUi1Rw=="
'--- numeric
Private Const LNG_SHA256_HASHSZ         As Long = 32
Private Const LNG_SHA256_BLOCKSZ        As Long = 64
Private Const LNG_SHA384_HASHSZ         As Long = 48
Private Const LNG_SHA384_BLOCKSZ        As Long = 128
Private Const LNG_SHA384_CONTEXTSZ      As Long = 200
Private Const LNG_HMAC_INNER_PAD        As Long = &H36
Private Const LNG_HMAC_OUTER_PAD        As Long = &H5C
Private Const LNG_FACILITY_WIN32        As Long = &H80070000
Private Const LNG_CHACHA20_KEYSZ        As Long = 32
Private Const LNG_CHACHA20POLY1305_IVSZ As Long = 12
Private Const LNG_CHACHA20POLY1305_TAGSZ As Long = 16
Private Const LNG_AES128_KEYSZ          As Long = 16
Private Const LNG_AES256_KEYSZ          As Long = 32
Private Const LNG_AESGCM_IVSZ           As Long = 12
Private Const LNG_AESGCM_TAGSZ          As Long = 16
Private Const LNG_LIBSODIUM_SHA512_CONTEXTSZ As Long = 64 + 16 + 128
'--- errors
Private Const ERR_OUT_OF_MEMORY         As Long = 8

Private m_uData                    As UcsCryptoThunkData

Private Enum UcsThunkPfnIndexEnum
    ucsPfnSecp256r1MakeKey = 1
    ucsPfnSecp256r1SharedSecret
    ucsPfnSecp256r1UncompressKey
    ucsPfnCurve25519ScalarMultiply
    ucsPfnCurve25519ScalarMultBase
    ucsPfnSha256Init
    ucsPfnSha256Update
    ucsPfnSha256Final
    ucsPfnSha384Init
    ucsPfnSha384Update
    ucsPfnSha384Final
    ucsPfnChacha20Poly1305Encrypt
    ucsPfnChacha20Poly1305Decrypt
    ucsPfnAesGcmEncrypt
    ucsPfnAesGcmDecrypt
    [_ucsPfnMax]
End Enum

Private Type UcsCryptoThunkData
    Thunk               As Long
    Glob()              As Byte
    Pfn(1 To [_ucsPfnMax] - 1) As Long
    EccKeySize          As Long
#If ImplUseLibSodium Then
    HashCtx(0 To LNG_LIBSODIUM_SHA512_CONTEXTSZ - 1) As Byte
#Else
    HashCtx(0 To LNG_SHA384_CONTEXTSZ - 1) As Byte
#End If
    HashPad(0 To LNG_SHA384_BLOCKSZ - 1 + 1000) As Byte
    HashFinal(0 To LNG_SHA384_HASHSZ - 1 + 1000) As Byte
    hRandomProv         As Long
#If ImplUseBCrypt Then
    hEcdhP256Prov       As Long
#End If
End Type

Public Type UcsRsaContextType
    hProv               As Long
    hPrivKey            As Long
    hPubKey             As Long
    HashAlgId           As Long
End Type

'=========================================================================
' Functions
'=========================================================================

Public Function CryptoInit() As Boolean
    Dim lOffset         As Long
    Dim lIdx            As Long
    Dim hResult          As Long
    Dim sApiSource      As String
    
    With m_uData
        #If ImplUseLibSodium Then
            If GetModuleHandle("libsodium.dll") = 0 Then
                Call LoadLibrary(App.Path & "\libsodium.dll")
                If sodium_init() < 0 Then
                    hResult = ERR_OUT_OF_MEMORY
                    sApiSource = "sodium_init"
                    GoTo QH
                End If
            End If
        #Else
            If .hRandomProv = 0 Then
                If CryptAcquireContext(.hRandomProv, 0, 0, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT) = 0 Then
                    hResult = Err.LastDllError
                    sApiSource = "CryptAcquireContext"
                    GoTo QH
                End If
            End If
        #End If
        #If ImplUseBCrypt Then
            If .hEcdhP256Prov = 0 Then
                hResult = BCryptOpenAlgorithmProvider(.hEcdhP256Prov, StrPtr("ECDH_P256"), StrPtr("Microsoft Primitive Provider"), 0)
                If hResult < 0 Then
                    sApiSource = "BCryptOpenAlgorithmProvider"
                    GoTo QH
                End If
            End If
        #End If
        If m_uData.Thunk = 0 Then
            .EccKeySize = 32
            '--- prepare thunk/context in executable memory
            .Thunk = pvThunkAllocate(STR_THUNK1 & STR_THUNK2 & STR_THUNK3)
            If .Thunk = 0 Then
                hResult = ERR_OUT_OF_MEMORY
                sApiSource = "VirtualAlloc"
                GoTo QH
            End If
            ReDim .Glob(0 To (Len(STR_GLOB) \ 4) * 3 - 1) As Byte
            pvThunkAllocate STR_GLOB, VarPtr(.Glob(0))
            '--- init pfns from thunk addr + offsets stored at beginning of it
            For lIdx = LBound(.Pfn) To UBound(.Pfn)
                Call CopyMemory(lOffset, ByVal UnsignedAdd(.Thunk, 4 * lIdx), 4)
                .Pfn(lIdx) = UnsignedAdd(.Thunk, lOffset)
            Next
            '--- init pfns trampolines
            Call pvPatchTrampoline(AddressOf pvCryptoCallSecp256r1MakeKey)
            Call pvPatchTrampoline(AddressOf pvCryptoCallSecp256r1SharedSecret)
            Call pvPatchTrampoline(AddressOf pvCryptoCallSecp256r1UncompressKey)
            Call pvPatchTrampoline(AddressOf pvCryptoCallCurve25519Multiply)
            Call pvPatchTrampoline(AddressOf pvCryptoCallCurve25519MulBase)
            Call pvPatchTrampoline(AddressOf pvCryptoCallSha256Init)
            Call pvPatchTrampoline(AddressOf pvCryptoCallSha256Update)
            Call pvPatchTrampoline(AddressOf pvCryptoCallSha256Final)
            Call pvPatchTrampoline(AddressOf pvCryptoCallSha384Init)
            Call pvPatchTrampoline(AddressOf pvCryptoCallSha384Update)
            Call pvPatchTrampoline(AddressOf pvCryptoCallSha384Final)
            Call pvPatchTrampoline(AddressOf pvCryptoCallChacha20Poly1305Encrypt)
            Call pvPatchTrampoline(AddressOf pvCryptoCallChacha20Poly1305Decrypt)
            Call pvPatchTrampoline(AddressOf pvCryptoCallAesGcmEncrypt)
            Call pvPatchTrampoline(AddressOf pvCryptoCallAesGcmDecrypt)
            '--- init thunk's first 4 bytes -> global data in C/C++
            Call CopyMemory(ByVal .Thunk, VarPtr(.Glob(0)), 4)
        End If
    End With
    '--- success
    CryptoInit = True
QH:
    If LenB(sApiSource) <> 0 Then
        Err.Raise IIf(hResult < 0, hResult, hResult Or LNG_FACILITY_WIN32), sApiSource
    End If
End Function

Public Sub CryptoTerminate()
    With m_uData
        #If Not ImplUseLibSodium Then
            If .hRandomProv <> 0 Then
                Call CryptReleaseContext(.hRandomProv, 0)
                .hRandomProv = 0
            End If
        #End If
        #If ImplUseBCrypt Then
            If .hEcdhP256Prov <> 0 Then
                Call BCryptCloseAlgorithmProvider(.hEcdhP256Prov, 0)
                .hEcdhP256Prov = 0
            End If
        #End If
    End With
End Sub

Public Function CryptoIsSupported(ByVal eAead As UcsTlsCryptoAlgorithmsEnum) As Boolean
    Const PREF          As Long = &H1000
    
    Select Case eAead
    Case ucsTlsAlgoAeadAes128, ucsTlsAlgoAeadAes256
        #If ImplUseLibSodium Then
            CryptoIsSupported = (crypto_aead_aes256gcm_is_available() <> 0 And eAead = ucsTlsAlgoAeadAes256)
        #Else
            CryptoIsSupported = True
        #End If
    Case PREF + ucsTlsAlgoAeadAes128, PREF + ucsTlsAlgoAeadAes256
        '--- signal if AES preferred over Chacha20
        #If ImplUseLibSodium Then
            CryptoIsSupported = (crypto_aead_aes256gcm_is_available() <> 0 And eAead = PREF + ucsTlsAlgoAeadAes256)
        #End If
    Case Else
        CryptoIsSupported = True
    End Select
End Function

Public Function CryptoEccSecp256r1MakeKey(baPrivate() As Byte, baPublic() As Byte) As Boolean
    Const MAX_RETRIES   As Long = 16
    Dim lIdx            As Long
    
    #If ImplUseBCrypt Then
        CryptoEccSecp256r1MakeKey = pvBCryptEcdhP256KeyPair(baPrivate, baPublic)
    #Else
        ReDim baPrivate(0 To m_uData.EccKeySize - 1) As Byte
        ReDim baPublic(0 To m_uData.EccKeySize) As Byte
        For lIdx = 1 To MAX_RETRIES
            CryptoRandomBytes VarPtr(baPrivate(0)), m_uData.EccKeySize
            If pvCryptoCallSecp256r1MakeKey(m_uData.Pfn(ucsPfnSecp256r1MakeKey), baPublic(0), baPrivate(0)) = 1 Then
                Exit For
            End If
        Next
        '--- success (or failure)
        CryptoEccSecp256r1MakeKey = (lIdx <= MAX_RETRIES)
    #End If
End Function

Public Function CryptoEccSecp256r1SharedSecret(baPrivate() As Byte, baPublic() As Byte) As Byte()
    Dim baRetVal()      As Byte
    
    #If ImplUseBCrypt Then
        Debug.Assert pvArraySize(baPrivate) = BCRYPT_SECP256R1_PRIVATE_KEYSZ
        Debug.Assert pvArraySize(baPublic) = BCRYPT_SECP256R1_COMPRESSED_PUBLIC_KEYSZ Or pvArraySize(baPublic) = BCRYPT_SECP256R1_UNCOMPRESSED_PUBLIC_KEYSZ
        baRetVal = pvBCryptEcdhP256AgreedSecret(baPrivate, baPublic)
    #Else
        Debug.Assert UBound(baPrivate) >= m_uData.EccKeySize - 1
        Debug.Assert UBound(baPublic) >= m_uData.EccKeySize
        ReDim baRetVal(0 To m_uData.EccKeySize - 1) As Byte
        If pvCryptoCallSecp256r1SharedSecret(m_uData.Pfn(ucsPfnSecp256r1SharedSecret), baPublic(0), baPrivate(0), baRetVal(0)) = 0 Then
            GoTo QH
        End If
    #End If
    CryptoEccSecp256r1SharedSecret = baRetVal
QH:
End Function

Public Function CryptoEccSecp256r1UncompressKey(baPublic() As Byte) As Byte()
    Dim baRetVal()      As Byte
    
    ReDim baRetVal(0 To 2 * m_uData.EccKeySize) As Byte
    If pvCryptoCallSecp256r1UncompressKey(m_uData.Pfn(ucsPfnSecp256r1UncompressKey), baPublic(0), baRetVal(0)) = 0 Then
        GoTo QH
    End If
    CryptoEccSecp256r1UncompressKey = baRetVal
QH:
End Function

Public Function CryptoEccCurve25519MakeKey(baPrivate() As Byte, baPublic() As Byte) As Boolean
    ReDim baPrivate(0 To m_uData.EccKeySize - 1) As Byte
    ReDim baPublic(0 To m_uData.EccKeySize - 1) As Byte
    CryptoRandomBytes VarPtr(baPrivate(0)), m_uData.EccKeySize
    '--- fix issues w/ specific privkeys
    baPrivate(0) = baPrivate(0) And 248
    baPrivate(UBound(baPrivate)) = (baPrivate(UBound(baPrivate)) And 127) Or 64
    #If ImplUseLibSodium Then
        Call crypto_scalarmult_curve25519_base(baPublic(0), baPrivate(0))
    #Else
        pvCryptoCallCurve25519MulBase m_uData.Pfn(ucsPfnCurve25519ScalarMultBase), baPublic(0), baPrivate(0)
    #End If
    '--- success
    CryptoEccCurve25519MakeKey = True
End Function

Public Function CryptoEccCurve25519SharedSecret(baPrivate() As Byte, baPublic() As Byte) As Byte()
    Dim baRetVal()      As Byte
    
    Debug.Assert UBound(baPrivate) >= m_uData.EccKeySize - 1
    Debug.Assert UBound(baPublic) >= m_uData.EccKeySize - 1
    ReDim baRetVal(0 To m_uData.EccKeySize - 1) As Byte
    #If ImplUseLibSodium Then
        Call crypto_scalarmult_curve25519(baRetVal(0), baPrivate(0), baPublic(0))
    #Else
        pvCryptoCallCurve25519Multiply m_uData.Pfn(ucsPfnCurve25519ScalarMultiply), baRetVal(0), baPrivate(0), baPublic(0)
    #End If
    CryptoEccCurve25519SharedSecret = baRetVal
End Function

Public Function CryptoHashSha256(baInput() As Byte, ByVal lPos As Long, Optional ByVal Size As Long = -1) As Byte()
    Dim lCtxPtr         As Long
    Dim lPtr            As Long
    Dim baRetVal()      As Byte
    
    If Size < 0 Then
        Size = pvArraySize(baInput) - lPos
    Else
        Debug.Assert pvArraySize(baInput) >= lPos + Size
    End If
    If Size > 0 Then
        lPtr = VarPtr(baInput(lPos))
    End If
    ReDim baRetVal(0 To LNG_SHA256_HASHSZ - 1) As Byte
    #If ImplUseLibSodium Then
        Call crypto_hash_sha256(baRetVal(0), ByVal lPtr, Size)
    #Else
        With m_uData
            lCtxPtr = VarPtr(.HashCtx(0))
            pvCryptoCallSha256Init .Pfn(ucsPfnSha256Init), lCtxPtr
            pvCryptoCallSha256Update .Pfn(ucsPfnSha256Update), lCtxPtr, lPtr, Size
            pvCryptoCallSha256Final .Pfn(ucsPfnSha256Final), lCtxPtr, baRetVal(0)
        End With
    #End If
    CryptoHashSha256 = baRetVal
End Function

Public Function CryptoHashSha384(baInput() As Byte, ByVal lPos As Long, Optional ByVal Size As Long = -1) As Byte()
    Dim lCtxPtr         As Long
    Dim lPtr            As Long
    Dim baRetVal()      As Byte
    
    If Size < 0 Then
        Size = pvArraySize(baInput) - lPos
    Else
        Debug.Assert pvArraySize(baInput) >= lPos + Size
    End If
    If Size > 0 Then
        lPtr = VarPtr(baInput(lPos))
    End If
    ReDim baRetVal(0 To LNG_SHA384_HASHSZ - 1) As Byte
    With m_uData
        lCtxPtr = VarPtr(.HashCtx(0))
        #If ImplUseLibSodium Then
            Call crypto_hash_sha384_init(.HashCtx)
            Call crypto_hash_sha512_update(ByVal lCtxPtr, ByVal lPtr, Size)
            Call crypto_hash_sha512_final(ByVal lCtxPtr, .HashFinal(0))
            Call CopyMemory(baRetVal(0), .HashFinal(0), LNG_SHA384_HASHSZ)
        #Else
            pvCryptoCallSha384Init .Pfn(ucsPfnSha384Init), lCtxPtr
            pvCryptoCallSha384Update .Pfn(ucsPfnSha384Update), lCtxPtr, lPtr, Size
            pvCryptoCallSha384Final .Pfn(ucsPfnSha384Final), lCtxPtr, baRetVal(0)
        #End If
    End With
    CryptoHashSha384 = baRetVal
End Function

Public Function CryptoHmacSha256(baKey() As Byte, baInput() As Byte, ByVal lPos As Long, Optional ByVal Size As Long = -1) As Byte()
    Dim lCtxPtr         As Long
    Dim lPtr            As Long
    Dim lIdx            As Long
    
    Debug.Assert UBound(baKey) < LNG_SHA256_BLOCKSZ
    If Size < 0 Then
        Size = pvArraySize(baInput) - lPos
    Else
        Debug.Assert pvArraySize(baInput) >= lPos + Size
    End If
    If Size > 0 Then
        lPtr = VarPtr(baInput(lPos))
    End If
    With m_uData
        lCtxPtr = VarPtr(.HashCtx(0))
        ReDim baRetVal(0 To LNG_SHA256_HASHSZ - 1) As Byte
        #If ImplUseLibSodium Then
            '-- inner hash
            Call crypto_hash_sha256_init(ByVal lCtxPtr)
            Call FillMemory(.HashPad(0), LNG_SHA256_BLOCKSZ, LNG_HMAC_INNER_PAD)
            For lIdx = 0 To UBound(baKey)
                .HashPad(lIdx) = baKey(lIdx) Xor LNG_HMAC_INNER_PAD
            Next
            Call crypto_hash_sha256_update(ByVal lCtxPtr, .HashPad(0), LNG_SHA256_BLOCKSZ)
            Call crypto_hash_sha256_update(ByVal lCtxPtr, ByVal lPtr, Size)
            Call crypto_hash_sha256_final(ByVal lCtxPtr, .HashFinal(0))
            '-- outer hash
            Call crypto_hash_sha256_init(ByVal lCtxPtr)
            Call FillMemory(.HashPad(0), LNG_SHA256_BLOCKSZ, LNG_HMAC_OUTER_PAD)
            For lIdx = 0 To UBound(baKey)
                .HashPad(lIdx) = baKey(lIdx) Xor LNG_HMAC_OUTER_PAD
            Next
            Call crypto_hash_sha256_update(ByVal lCtxPtr, .HashPad(0), LNG_SHA256_BLOCKSZ)
            Call crypto_hash_sha256_update(ByVal lCtxPtr, .HashFinal(0), LNG_SHA256_HASHSZ)
            Call crypto_hash_sha256_final(ByVal lCtxPtr, baRetVal(0))
        #Else
            '-- inner hash
            pvCryptoCallSha256Init .Pfn(ucsPfnSha256Init), lCtxPtr
            Call FillMemory(.HashPad(0), LNG_SHA256_BLOCKSZ, LNG_HMAC_INNER_PAD)
            For lIdx = 0 To UBound(baKey)
                .HashPad(lIdx) = baKey(lIdx) Xor LNG_HMAC_INNER_PAD
            Next
            pvCryptoCallSha256Update .Pfn(ucsPfnSha256Update), lCtxPtr, VarPtr(.HashPad(0)), LNG_SHA256_BLOCKSZ
            pvCryptoCallSha256Update .Pfn(ucsPfnSha256Update), lCtxPtr, lPtr, Size
            pvCryptoCallSha256Final .Pfn(ucsPfnSha256Final), lCtxPtr, .HashFinal(0)
            '-- outer hash
            pvCryptoCallSha256Init .Pfn(ucsPfnSha256Init), lCtxPtr
            Call FillMemory(.HashPad(0), LNG_SHA256_BLOCKSZ, LNG_HMAC_OUTER_PAD)
            For lIdx = 0 To UBound(baKey)
                .HashPad(lIdx) = baKey(lIdx) Xor LNG_HMAC_OUTER_PAD
            Next
            pvCryptoCallSha256Update .Pfn(ucsPfnSha256Update), lCtxPtr, VarPtr(.HashPad(0)), LNG_SHA256_BLOCKSZ
            pvCryptoCallSha256Update .Pfn(ucsPfnSha256Update), lCtxPtr, VarPtr(.HashFinal(0)), LNG_SHA256_HASHSZ
            pvCryptoCallSha256Final .Pfn(ucsPfnSha256Final), lCtxPtr, baRetVal(0)
        #End If
    End With
    CryptoHmacSha256 = baRetVal
End Function

Public Function CryptoHmacSha384(baKey() As Byte, baInput() As Byte, ByVal lPos As Long, Optional ByVal Size As Long = -1) As Byte()
    Dim lCtxPtr         As Long
    Dim lPtr            As Long
    Dim lIdx            As Long
    
    Debug.Assert UBound(baKey) < LNG_SHA384_BLOCKSZ
    If Size < 0 Then
        Size = pvArraySize(baInput) - lPos
    Else
        Debug.Assert pvArraySize(baInput) >= lPos + Size
    End If
    If Size > 0 Then
        lPtr = VarPtr(baInput(lPos))
    End If
    With m_uData
        lCtxPtr = VarPtr(.HashCtx(0))
        ReDim baRetVal(0 To LNG_SHA384_HASHSZ - 1) As Byte
        #If ImplUseLibSodium Then
            '-- inner hash
            Call crypto_hash_sha384_init(.HashCtx)
            Call FillMemory(.HashPad(0), LNG_SHA384_BLOCKSZ, LNG_HMAC_INNER_PAD)
            For lIdx = 0 To UBound(baKey)
                .HashPad(lIdx) = baKey(lIdx) Xor LNG_HMAC_INNER_PAD
            Next
            Call crypto_hash_sha512_update(ByVal lCtxPtr, .HashPad(0), LNG_SHA384_BLOCKSZ)
            Call crypto_hash_sha512_update(ByVal lCtxPtr, ByVal lPtr, Size)
            Call crypto_hash_sha512_final(ByVal lCtxPtr, .HashFinal(0))
            '-- outer hash
            Call crypto_hash_sha384_init(.HashCtx)
            Call FillMemory(.HashPad(0), LNG_SHA384_BLOCKSZ, LNG_HMAC_OUTER_PAD)
            For lIdx = 0 To UBound(baKey)
                .HashPad(lIdx) = baKey(lIdx) Xor LNG_HMAC_OUTER_PAD
            Next
            Call crypto_hash_sha512_update(ByVal lCtxPtr, .HashPad(0), LNG_SHA384_BLOCKSZ)
            Call crypto_hash_sha512_update(ByVal lCtxPtr, .HashFinal(0), LNG_SHA384_HASHSZ)
            Call crypto_hash_sha512_final(ByVal lCtxPtr, .HashFinal(0))
            Call CopyMemory(baRetVal(0), .HashFinal(0), LNG_SHA384_HASHSZ)
        #Else
            '-- inner hash
            pvCryptoCallSha384Init .Pfn(ucsPfnSha384Init), lCtxPtr
            Call FillMemory(.HashPad(0), LNG_SHA384_BLOCKSZ, LNG_HMAC_INNER_PAD)
            For lIdx = 0 To UBound(baKey)
                .HashPad(lIdx) = baKey(lIdx) Xor LNG_HMAC_INNER_PAD
            Next
            pvCryptoCallSha384Update .Pfn(ucsPfnSha384Update), lCtxPtr, VarPtr(.HashPad(0)), LNG_SHA384_BLOCKSZ
            pvCryptoCallSha384Update .Pfn(ucsPfnSha384Update), lCtxPtr, lPtr, Size
            pvCryptoCallSha384Final .Pfn(ucsPfnSha384Final), lCtxPtr, .HashFinal(0)
            '-- outer hash
            pvCryptoCallSha384Init .Pfn(ucsPfnSha384Init), lCtxPtr
            Call FillMemory(.HashPad(0), LNG_SHA384_BLOCKSZ, LNG_HMAC_OUTER_PAD)
            For lIdx = 0 To UBound(baKey)
                .HashPad(lIdx) = baKey(lIdx) Xor LNG_HMAC_OUTER_PAD
            Next
            pvCryptoCallSha384Update .Pfn(ucsPfnSha384Update), lCtxPtr, VarPtr(.HashPad(0)), LNG_SHA384_BLOCKSZ
            pvCryptoCallSha384Update .Pfn(ucsPfnSha384Update), lCtxPtr, VarPtr(.HashFinal(0)), LNG_SHA384_HASHSZ
            pvCryptoCallSha384Final .Pfn(ucsPfnSha384Final), lCtxPtr, baRetVal(0)
        #End If
    End With
    CryptoHmacSha384 = baRetVal
End Function

Public Function CryptoAeadChacha20Poly1305Encrypt( _
            baNonce() As Byte, baKey() As Byte, _
            baAad() As Byte, ByVal lAadPos As Long, ByVal lAdSize As Long, _
            baBuffer() As Byte, ByVal lPos As Long, ByVal lSize As Long) As Boolean
    Dim lAdPtr          As Long
    
    Debug.Assert pvArraySize(baNonce) = LNG_CHACHA20POLY1305_IVSZ
    Debug.Assert pvArraySize(baKey) = LNG_CHACHA20_KEYSZ
    Debug.Assert pvArraySize(baBuffer) >= lPos + lSize + LNG_CHACHA20POLY1305_TAGSZ
    If lSize > 0 Then
        If lAdSize > 0 Then
            lAdPtr = VarPtr(baAad(lAadPos))
        End If
        #If ImplUseLibSodium Then
            Call crypto_aead_chacha20poly1305_ietf_encrypt(baBuffer(lPos), ByVal 0, baBuffer(lPos), lSize, 0, ByVal lAdPtr, lAdSize, 0, 0, baNonce(0), baKey(0))
        #Else
            Call pvCryptoCallChacha20Poly1305Encrypt(m_uData.Pfn(ucsPfnChacha20Poly1305Encrypt), _
                    baKey(0), baNonce(0), _
                    lAdPtr, lAdSize, _
                    baBuffer(lPos), lSize, _
                    baBuffer(lPos), baBuffer(lPos + lSize))
        #End If
    End If
    '--- success
    CryptoAeadChacha20Poly1305Encrypt = True
End Function

Public Function CryptoAeadChacha20Poly1305Decrypt( _
            baNonce() As Byte, baKey() As Byte, _
            baAad() As Byte, ByVal lAadPos As Long, ByVal lAdSize As Long, _
            baBuffer() As Byte, ByVal lPos As Long, ByVal lSize As Long) As Boolean
    Debug.Assert pvArraySize(baNonce) = LNG_CHACHA20POLY1305_IVSZ
    Debug.Assert pvArraySize(baKey) = LNG_CHACHA20_KEYSZ
    Debug.Assert pvArraySize(baBuffer) >= lPos + lSize
    #If ImplUseLibSodium Then
        If crypto_aead_chacha20poly1305_ietf_decrypt(baBuffer(lPos), ByVal 0, 0, baBuffer(lPos), lSize, 0, baAad(lAadPos), lAdSize, 0, baNonce(0), baKey(0)) = 0 Then
            '--- success
            CryptoAeadChacha20Poly1305Decrypt = True
        End If
    #Else
        If pvCryptoCallChacha20Poly1305Decrypt(m_uData.Pfn(ucsPfnChacha20Poly1305Decrypt), _
                baKey(0), baNonce(0), _
                baAad(lAadPos), lAdSize, _
                baBuffer(lPos), lSize - LNG_CHACHA20POLY1305_TAGSZ, _
                baBuffer(lPos + lSize - LNG_CHACHA20POLY1305_TAGSZ), baBuffer(lPos)) = 0 Then
            '--- success
            CryptoAeadChacha20Poly1305Decrypt = True
        End If
    #End If
End Function

Public Function CryptoAeadAesGcmEncrypt( _
            baNonce() As Byte, baKey() As Byte, _
            baAad() As Byte, ByVal lAadPos As Long, ByVal lAdSize As Long, _
            baBuffer() As Byte, ByVal lPos As Long, ByVal lSize As Long) As Boolean
    Dim lAdPtr          As Long
    
    Debug.Assert pvArraySize(baNonce) = LNG_AESGCM_IVSZ
    #If ImplUseLibSodium Then
        Debug.Assert pvArraySize(baKey) = LNG_AES256_KEYSZ
    #Else
        Debug.Assert pvArraySize(baKey) = LNG_AES128_KEYSZ Or pvArraySize(baKey) = LNG_AES256_KEYSZ
    #End If
    Debug.Assert pvArraySize(baBuffer) >= lPos + lSize + LNG_AESGCM_TAGSZ
    If lSize > 0 Then
        If lAdSize > 0 Then
            lAdPtr = VarPtr(baAad(lAadPos))
        End If
        #If ImplUseLibSodium Then
            Call crypto_aead_aes256gcm_encrypt(baBuffer(lPos), ByVal 0, baBuffer(lPos), lSize, 0, ByVal lAdPtr, lAdSize, 0, 0, baNonce(0), baKey(0))
        #Else
            Call pvCryptoCallAesGcmEncrypt(m_uData.Pfn(ucsPfnAesGcmEncrypt), _
                    baBuffer(lPos), baBuffer(lPos + lSize), _
                    baBuffer(lPos), lSize, _
                    lAdPtr, lAdSize, _
                    baNonce(0), baKey(0), UBound(baKey) + 1)
        #End If
    End If
    '--- success
    CryptoAeadAesGcmEncrypt = True
End Function

Public Function CryptoAeadAesGcmDecrypt( _
            baNonce() As Byte, baKey() As Byte, _
            baAad() As Byte, ByVal lAadPos As Long, ByVal lAdSize As Long, _
            baBuffer() As Byte, ByVal lPos As Long, ByVal lSize As Long) As Boolean
    Debug.Assert pvArraySize(baNonce) = LNG_AESGCM_IVSZ
    #If ImplUseLibSodium Then
        Debug.Assert pvArraySize(baKey) = LNG_AES256_KEYSZ
    #Else
        Debug.Assert pvArraySize(baKey) = LNG_AES128_KEYSZ Or pvArraySize(baKey) = LNG_AES256_KEYSZ
    #End If
    Debug.Assert pvArraySize(baBuffer) >= lPos + lSize
    #If ImplUseLibSodium Then
        If crypto_aead_aes256gcm_decrypt(baBuffer(lPos), ByVal 0, 0, baBuffer(lPos), lSize, 0, baAad(lAadPos), lAdSize, 0, baNonce(0), baKey(0)) = 0 Then
            '--- success
            CryptoAeadAesGcmDecrypt = True
        End If
    #Else
        If pvCryptoCallAesGcmDecrypt(m_uData.Pfn(ucsPfnAesGcmDecrypt), _
                baBuffer(lPos), _
                baBuffer(lPos), lSize - LNG_AESGCM_TAGSZ, _
                baBuffer(lPos + lSize - LNG_AESGCM_TAGSZ), _
                baAad(lAadPos), lAdSize, _
                baNonce(0), baKey(0), UBound(baKey) + 1) = 0 Then
            '--- success
            CryptoAeadAesGcmDecrypt = True
        End If
    #End If
End Function

Public Sub CryptoRandomBytes(ByVal lPtr As Long, ByVal lSize As Long)
    #If ImplUseLibSodium Then
        Call randombytes_buf(lPtr, lSize)
    #Else
        Call CryptGenRandom(m_uData.hRandomProv, lSize, lPtr)
    #End If
End Sub

'= RSA helpers ===========================================================

Public Function CryptoRsaInitContext(uCtx As UcsRsaContextType, baPrivKey() As Byte, baCert() As Byte, baPubKey() As Byte, Optional ByVal SignatureType As Long) As Boolean
    Dim lHashAlgId      As Long
    Dim hProv           As Long
    Dim lPkiPtr         As Long
    Dim lKeyPtr         As Long
    Dim lKeySize        As Long
    Dim uKeyBlob        As CRYPT_DER_BLOB
    Dim hPrivKey        As Long
    Dim pContext        As Long
    Dim lPtr            As Long
    Dim hPubKey         As Long
    Dim hResult         As Long
    Dim sApiSource      As String
    
    If SignatureType = TLS_SIGNATURE_RSA_PKCS1_SHA1 Then
        lHashAlgId = CALG_SHA1
    ElseIf SignatureType = TLS_SIGNATURE_RSA_PKCS1_SHA256 Then
        lHashAlgId = CALG_SHA_256
    ElseIf SignatureType <> 0 Then
        GoTo QH
    End If
    If CryptAcquireContext(hProv, 0, 0, IIf(lHashAlgId = CALG_SHA_256, PROV_RSA_AES, PROV_RSA_FULL), CRYPT_VERIFYCONTEXT) = 0 Then
        hResult = Err.LastDllError
        sApiSource = "CryptAcquireContext"
        GoTo QH
    End If
    If pvArraySize(baPrivKey) > 0 Then
        If CryptDecodeObjectEx(X509_ASN_ENCODING Or PKCS_7_ASN_ENCODING, PKCS_PRIVATE_KEY_INFO, baPrivKey(0), UBound(baPrivKey) + 1, CRYPT_DECODE_ALLOC_FLAG, 0, lPkiPtr, 0) = 0 Then
            hResult = Err.LastDllError
            sApiSource = "CryptDecodeObjectEx(PKCS_PRIVATE_KEY_INFO)"
            GoTo QH
        End If
        Call CopyMemory(uKeyBlob, ByVal UnsignedAdd(lPkiPtr, 16), Len(uKeyBlob)) '--- dereference PCRYPT_PRIVATE_KEY_INFO->PrivateKey
        If CryptDecodeObjectEx(X509_ASN_ENCODING Or PKCS_7_ASN_ENCODING, PKCS_RSA_PRIVATE_KEY, ByVal uKeyBlob.pbData, uKeyBlob.cbData, CRYPT_DECODE_ALLOC_FLAG, 0, lKeyPtr, lKeySize) = 0 Then
            hResult = Err.LastDllError
            sApiSource = "CryptDecodeObjectEx(PKCS_RSA_PRIVATE_KEY)"
            GoTo QH
        End If
        If CryptImportKey(hProv, ByVal lKeyPtr, lKeySize, 0, 0, hPrivKey) = 0 Then
            hResult = Err.LastDllError
            sApiSource = "CryptImportKey"
            GoTo QH
        End If
    End If
    If pvArraySize(baCert) > 0 Then
        pContext = CertCreateCertificateContext(X509_ASN_ENCODING Or PKCS_7_ASN_ENCODING, baCert(0), UBound(baCert) + 1)
        If pContext = 0 Then
            hResult = Err.LastDllError
            sApiSource = "CertCreateCertificateContext"
            GoTo QH
        End If
        Call CopyMemory(lPtr, ByVal UnsignedAdd(pContext, 12), 4)       '--- dereference pContext->pCertInfo
        lPtr = UnsignedAdd(lPtr, 56)                                    '--- &pContext->pCertInfo->SubjectPublicKeyInfo
        If CryptImportPublicKeyInfo(hProv, X509_ASN_ENCODING Or PKCS_7_ASN_ENCODING, ByVal lPtr, hPubKey) = 0 Then
            hResult = Err.LastDllError
            sApiSource = "CryptImportPublicKeyInfo#1"
            GoTo QH
        End If
    ElseIf pvArraySize(baPubKey) > 0 Then
        If CryptDecodeObjectEx(X509_ASN_ENCODING Or PKCS_7_ASN_ENCODING, X509_PUBLIC_KEY_INFO, baPubKey(0), UBound(baPubKey) + 1, CRYPT_DECODE_ALLOC_FLAG, 0, lKeyPtr, 0) = 0 Then
            hResult = Err.LastDllError
            sApiSource = "CryptDecodeObjectEx(PKCS_PRIVATE_KEY_INFO)"
            GoTo QH
        End If
        If CryptImportPublicKeyInfo(hProv, X509_ASN_ENCODING Or PKCS_7_ASN_ENCODING, ByVal lKeyPtr, hPubKey) = 0 Then
            hResult = Err.LastDllError
            sApiSource = "CryptImportPublicKeyInfo#2"
            GoTo QH
        End If
    End If
    '--- commit
    uCtx.hProv = hProv: hProv = 0
    uCtx.hPrivKey = hPrivKey: hPrivKey = 0
    uCtx.hPubKey = hPubKey: hPubKey = 0
    uCtx.HashAlgId = lHashAlgId
    '--- success
    CryptoRsaInitContext = True
QH:
    If hPrivKey <> 0 Then
        Call CryptDestroyKey(hPrivKey)
    End If
    If hPubKey <> 0 Then
        Call CryptDestroyKey(hPubKey)
    End If
    If pContext <> 0 Then
        Call CertFreeCertificateContext(pContext)
    End If
    If hProv <> 0 Then
        Call CryptReleaseContext(hProv, 0)
    End If
    If lPkiPtr <> 0 Then
        Call LocalFree(lPkiPtr)
    End If
    If lKeyPtr <> 0 Then
        Call LocalFree(lKeyPtr)
    End If
    If LenB(sApiSource) <> 0 Then
        Err.Raise IIf(hResult < 0, hResult, hResult Or LNG_FACILITY_WIN32), sApiSource
    End If
End Function

Public Sub CryptoRsaTerminateContext(uCtx As UcsRsaContextType)
    If uCtx.hPrivKey <> 0 Then
        Call CryptDestroyKey(uCtx.hPrivKey)
        uCtx.hPrivKey = 0
    End If
    If uCtx.hPubKey <> 0 Then
        Call CryptDestroyKey(uCtx.hPubKey)
        uCtx.hPubKey = 0
    End If
    If uCtx.hProv <> 0 Then
        Call CryptReleaseContext(uCtx.hProv, 0)
        uCtx.hProv = 0
    End If
End Sub

Public Function CryptoRsaSign(uCtx As UcsRsaContextType, baPlainText() As Byte) As Byte()
    Const MAX_SIG_SIZE  As Long = MAX_RSA_KEY / 8
    Dim baRetVal()      As Byte
    Dim hHash           As Long
    Dim lSize           As Long
    Dim hResult         As Long
    Dim sApiSource      As String
    
    If CryptCreateHash(uCtx.hProv, uCtx.HashAlgId, 0, 0, hHash) = 0 Then
        hResult = Err.LastDllError
        sApiSource = "CryptCreateHash"
        GoTo QH
    End If
    lSize = pvArraySize(baPlainText)
    If lSize > 0 Then
        If CryptHashData(hHash, baPlainText(0), lSize, 0) = 0 Then
            hResult = Err.LastDllError
            sApiSource = "CryptHashData"
            GoTo QH
        End If
    End If
    ReDim baRetVal(0 To MAX_SIG_SIZE - 1) As Byte
    lSize = UBound(baRetVal) + 1
    If CryptSignHash(hHash, AT_KEYEXCHANGE, 0, 0, baRetVal(0), lSize) = 0 Then
        hResult = Err.LastDllError
        sApiSource = "CryptSignHash"
        GoTo QH
    End If
    If UBound(baRetVal) <> lSize - 1 Then
        ReDim Preserve baRetVal(0 To lSize - 1) As Byte
    End If
    pvArrayReverse baRetVal
    CryptoRsaSign = baRetVal
QH:
    If hHash <> 0 Then
        Call CryptDestroyHash(hHash)
    End If
    If LenB(sApiSource) <> 0 Then
        Err.Raise IIf(hResult < 0, hResult, hResult Or LNG_FACILITY_WIN32), sApiSource
    End If
End Function

Public Function CryptoRsaVerify(uCtx As UcsRsaContextType, baPlainText() As Byte, baSignature() As Byte) As Boolean
    Dim hHash           As Long
    Dim lSize           As Long
    Dim hResult         As Long
    Dim sApiSource      As String
    Dim baRevSig()      As Byte
    
    If CryptCreateHash(uCtx.hProv, uCtx.HashAlgId, 0, 0, hHash) = 0 Then
        hResult = Err.LastDllError
        sApiSource = "CryptCreateHash"
        GoTo QH
    End If
    lSize = pvArraySize(baPlainText)
    If lSize > 0 Then
        If CryptHashData(hHash, baPlainText(0), lSize, 0) = 0 Then
            hResult = Err.LastDllError
            sApiSource = "CryptHashData"
            GoTo QH
        End If
    End If
    baRevSig = baSignature
    pvArrayReverse baRevSig
    If CryptVerifySignature(hHash, baRevSig(0), UBound(baRevSig) + 1, uCtx.hPubKey, 0, 0) = 0 Then
        hResult = Err.LastDllError
        '--- don't raise error on NTE_BAD_SIGNATURE
        If hResult <> NTE_BAD_SIGNATURE Then
            sApiSource = "CryptVerifySignature"
        End If
        GoTo QH
    End If
    '--- success
    CryptoRsaVerify = True
QH:
    If hHash <> 0 Then
        Call CryptDestroyHash(hHash)
    End If
    If LenB(sApiSource) <> 0 Then
        Err.Raise IIf(hResult < 0, hResult, hResult Or LNG_FACILITY_WIN32), sApiSource
    End If
End Function

#If False Then
Public Function CryptoRsaExtractPublicKey(baCert() As Byte) As Byte()
    Dim pContext        As Long
    Dim hProv           As Long
    Dim baRetVal()      As Byte
    Dim lSize           As Long
    Dim lPtr            As Long
    Dim hResult         As Long
    Dim sApiSource      As String

    If CryptAcquireContext(hProv, 0, 0, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT) = 0 Then
        hResult = Err.LastDllError
        sApiSource = "CryptAcquireContext"
        GoTo QH
    End If
    pContext = CertCreateCertificateContext(X509_ASN_ENCODING Or PKCS_7_ASN_ENCODING, baCert(0), UBound(baCert) + 1)
    If pContext = 0 Then
        hResult = Err.LastDllError
        sApiSource = "CertCreateCertificateContext"
        GoTo QH
    End If
    Call CopyMemory(lPtr, ByVal UnsignedAdd(pContext, 12), 4)       '--- dereference pContext->pCertInfo
    lPtr = UnsignedAdd(lPtr, 56)                                    '--- &pContext->pCertInfo->SubjectPublicKeyInfo
    '--- get required size first
    If CryptEncodeObjectEx(X509_ASN_ENCODING Or PKCS_7_ASN_ENCODING, X509_PUBLIC_KEY_INFO, ByVal lPtr, 0, 0, ByVal 0, lSize) = 0 Then
        hResult = Err.LastDllError
        sApiSource = "CryptEncodeObjectEx"
        GoTo QH
    End If
    ReDim baRetVal(0 To lSize - 1) As Byte
    If CryptEncodeObjectEx(X509_ASN_ENCODING Or PKCS_7_ASN_ENCODING, X509_PUBLIC_KEY_INFO, ByVal lPtr, 0, 0, baRetVal(0), lSize) = 0 Then
        hResult = Err.LastDllError
        sApiSource = "CryptEncodeObjectEx"
        GoTo QH
    End If
    If UBound(baRetVal) <> lSize - 1 Then
        ReDim Preserve baRetVal(0 To lSize - 1) As Byte
    End If
    CryptoRsaExtractPublicKey = baRetVal
QH:
    If hProv <> 0 Then
        Call CryptReleaseContext(hProv, 0)
    End If
    If pContext <> 0 Then
        Call CertFreeCertificateContext(pContext)
    End If
    If LenB(sApiSource) <> 0 Then
        Err.Raise IIf(hResult < 0, hResult, hResult Or LNG_FACILITY_WIN32), sApiSource
    End If
End Function
#End If

Public Function CryptoRsaEncrypt(ByVal hKey As Long, baPlainText() As Byte) As Byte()
    Dim baRetVal()      As Byte
    Dim lSize           As Long
    Dim hResult         As Long
    Dim sApiSource      As String
    
    lSize = pvArraySize(baPlainText)
    ReDim baRetVal(0 To (lSize + 1023) And Not 1023 - 1) As Byte
    Call CopyMemory(baRetVal(0), baPlainText(0), lSize)
    If CryptEncrypt(hKey, 0, 1, 0, baRetVal(0), lSize, UBound(baRetVal) + 1) = 0 Then
        hResult = Err.LastDllError
        sApiSource = "CryptEncrypt"
        GoTo QH
    End If
    ReDim Preserve baRetVal(0 To lSize - 1) As Byte
    pvArrayReverse baRetVal
    CryptoRsaEncrypt = baRetVal
QH:
    If LenB(sApiSource) <> 0 Then
        Err.Raise IIf(hResult < 0, hResult, hResult Or LNG_FACILITY_WIN32), sApiSource
    End If
End Function

Public Function SearchCollection(ByVal oCol As Collection, Index As Variant, Optional RetVal As Variant) As Boolean
    Dim vItem           As Variant
    
    If oCol Is Nothing Then
        GoTo QH
    ElseIf pvCryptoCallCollectionItem(oCol, Index, vItem) < 0 Then
        GoTo QH
    End If
    If IsObject(vItem) Then
        Set RetVal = vItem
    Else
        RetVal = vItem
    End If
    '--- success
    SearchCollection = True
QH:
End Function

'--- PEM = privacy-enhanced mail
Public Function CryptoPemGetTextPortions(sContents As String, sBoundary As String, Optional RetVal As Collection) As Collection
    Dim vSplit          As Variant
    Dim lIdx            As Long
    Dim lJdx            As Long
    Dim bInside         As Boolean
    Dim lStart          As Long
    Dim lSize           As Long
    Dim sPortion        As String
    
    If RetVal Is Nothing Then
        Set RetVal = New Collection
    End If
    vSplit = Split(Replace(sContents, vbCr, vbNullString), vbLf)
    For lIdx = 0 To UBound(vSplit)
        If Not bInside Then
            If InStr(vSplit(lIdx), "-----BEGIN " & sBoundary & "-----") > 0 Then
                lStart = lIdx + 1
                lSize = 0
                bInside = True
            End If
        Else
            If InStr(vSplit(lIdx), "-----END " & sBoundary & "-----") > 0 Then
                sPortion = String$(lSize, 0)
                lSize = 1
                For lJdx = lStart To lIdx - 1
                    If InStr(vSplit(lJdx), ":") = 0 Then
                        Mid$(sPortion, lSize, Len(vSplit(lJdx))) = vSplit(lJdx)
                        lSize = lSize + Len(vSplit(lJdx))
                    End If
                Next
                If Not SearchCollection(RetVal, sPortion) Then
                    RetVal.Add FromBase64Array(sPortion), sPortion
                End If
                bInside = False
            ElseIf InStr(vSplit(lIdx), ":") = 0 Then
                lSize = lSize + Len(vSplit(lIdx))
            End If
        End If
    Next
    Set CryptoPemGetTextPortions = RetVal
End Function

Public Function FromBase64Array(sText As String) As Byte()
    Dim baRetVal()      As Byte
    Dim lSize           As Long
    
    lSize = (Len(sText) \ 4) * 3
    ReDim baRetVal(0 To lSize - 1) As Byte
    pvThunkAllocate sText, VarPtr(baRetVal(0))
    If Right$(sText, 2) = "==" Then
        ReDim Preserve baRetVal(0 To lSize - 3)
    ElseIf Right$(sText, 1) = "=" Then
        ReDim Preserve baRetVal(0 To lSize - 2)
    End If
    FromBase64Array = baRetVal
End Function

'= private ===============================================================

Private Function pvArraySize(baArray() As Byte) As Long
    Dim lPtr            As Long
    
    '--- peek long at ArrPtr(baArray)
    Call CopyMemory(lPtr, ByVal ArrPtr(baArray), 4)
    If lPtr <> 0 Then
        pvArraySize = UBound(baArray) + 1
    End If
End Function

Private Sub pvArrayReverse(baData() As Byte)
    Dim lIdx            As Long
    Dim bTemp           As Byte
    
    For lIdx = 0 To UBound(baData) \ 2
        bTemp = baData(lIdx)
        baData(lIdx) = baData(UBound(baData) - lIdx)
        baData(UBound(baData) - lIdx) = bTemp
    Next
End Sub

Private Function pvThunkAllocate(sText As String, Optional ByVal ThunkPtr As Long) As Long
    Static Map(0 To &H3FF) As Long
    Dim baInput()       As Byte
    Dim lIdx            As Long
    Dim lChar           As Long
    Dim lPtr            As Long
    
    If ThunkPtr <> 0 Then
        pvThunkAllocate = ThunkPtr
    Else
        pvThunkAllocate = VirtualAlloc(0, (Len(sText) \ 4) * 3, MEM_COMMIT, PAGE_EXECUTE_READWRITE)
        If pvThunkAllocate = 0 Then
            Exit Function
        End If
    End If
    '--- init decoding maps
    If Map(65) = 0 Then
        baInput = StrConv("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", vbFromUnicode)
        For lIdx = 0 To UBound(baInput)
            lChar = baInput(lIdx)
            Map(&H0 + lChar) = lIdx * (2 ^ 2)
            Map(&H100 + lChar) = (lIdx And &H30) \ (2 ^ 4) Or (lIdx And &HF) * (2 ^ 12)
            Map(&H200 + lChar) = (lIdx And &H3) * (2 ^ 22) Or (lIdx And &H3C) * (2 ^ 6)
            Map(&H300 + lChar) = lIdx * (2 ^ 16)
        Next
    End If
    '--- base64 decode loop
    baInput = StrConv(Replace(Replace(sText, vbCr, vbNullString), vbLf, vbNullString), vbFromUnicode)
    lPtr = pvThunkAllocate
    For lIdx = 0 To UBound(baInput) - 3 Step 4
        lChar = Map(baInput(lIdx + 0)) Or Map(&H100 + baInput(lIdx + 1)) Or Map(&H200 + baInput(lIdx + 2)) Or Map(&H300 + baInput(lIdx + 3))
        Call CopyMemory(ByVal lPtr, lChar, 3)
        lPtr = UnsignedAdd(lPtr, 3)
    Next
End Function

Private Sub pvPatchTrampoline(ByVal Pfn As Long)
    Dim bInIDE          As Boolean
 
    Debug.Assert pvSetTrue(bInIDE)
    If bInIDE Then
        Call CopyMemory(Pfn, ByVal UnsignedAdd(Pfn, &H16), 4)
    Else
        Call VirtualProtect(Pfn, 8, PAGE_EXECUTE_READWRITE, 0)
    End If
    ' 0:  58                      pop    eax
    ' 1:  59                      pop    ecx
    ' 2:  50                      push   eax
    ' 3:  ff e1                   jmp    ecx
    ' 5:  90                      nop
    ' 6:  90                      nop
    ' 7:  90                      nop
    Call CopyMemory(ByVal Pfn, -802975883527609.7192@, 8)
End Sub

Private Sub pvPatchMethodTrampoline(ByVal Pfn As Long, ByVal lMethodIdx As Long)
    Dim bInIDE          As Boolean

    Debug.Assert pvSetTrue(bInIDE)
    If bInIDE Then
        '--- note: IDE is not large-address aware
        Call CopyMemory(Pfn, ByVal Pfn + &H16, 4)
    Else
        Call VirtualProtect(Pfn, 12, PAGE_EXECUTE_READWRITE, 0)
    End If
    ' 0: 8B 44 24 04          mov         eax,dword ptr [esp+4]
    ' 4: 8B 00                mov         eax,dword ptr [eax]
    ' 6: FF A0 00 00 00 00    jmp         dword ptr [eax+lMethodIdx*4]
    Call CopyMemory(ByVal Pfn, -684575231150992.4725@, 8)
    Call CopyMemory(ByVal (Pfn Xor &H80000000) + 8 Xor &H80000000, lMethodIdx * 4, 4)
End Sub

Private Function pvSetTrue(bValue As Boolean) As Boolean
    bValue = True
    pvSetTrue = True
End Function

Private Function UnsignedAdd(ByVal lUnsignedPtr As Long, ByVal lSignedOffset As Long) As Long
    '--- note: safely add *signed* offset to *unsigned* ptr for *unsigned* retval w/o overflow in LARGEADDRESSAWARE processes
    UnsignedAdd = ((lUnsignedPtr Xor &H80000000) + lSignedOffset) Xor &H80000000
End Function

#If ImplUseLibSodium Then
    Private Sub crypto_hash_sha384_init(baCtx() As Byte)
        Static baSha384State() As Byte
        
        If pvArraySize(baSha384State) = 0 Then
            ReDim baSha384State(0 To (Len(STR_LIBSODIUM_SHA384_STATE) \ 4) * 3 - 1) As Byte
            pvThunkAllocate STR_LIBSODIUM_SHA384_STATE, VarPtr(baSha384State(0))
            ReDim Preserve baSha384State(0 To 63) As Byte
        End If
        Debug.Assert pvArraySize(baCtx) >= crypto_hash_sha512_statebytes()
        Call crypto_hash_sha512_init(baCtx(0))
        Call CopyMemory(baCtx(0), baSha384State(0), UBound(baSha384State) + 1)
    End Sub
#End If

'= BCrypt helpers ========================================================

#If ImplUseBCrypt Then
Private Function pvBCryptEcdhP256KeyPair(baPriv() As Byte, baPub() As Byte) As Boolean
    Dim hProv           As Long
    Dim hResult         As Long
    Dim sApiSource      As String
    Dim hKeyPair        As Long
    Dim baBlob()        As Byte
    Dim cbResult        As Long
    
    hProv = m_uData.hEcdhP256Prov
    hResult = BCryptGenerateKeyPair(hProv, hKeyPair, 256, 0)
    If hResult < 0 Then
        sApiSource = "BCryptGenerateKeyPair"
        GoTo QH
    End If
    hResult = BCryptFinalizeKeyPair(hKeyPair, 0)
    If hResult < 0 Then
        sApiSource = "BCryptFinalizeKeyPair"
        GoTo QH
    End If
    ReDim baBlob(0 To 1023) As Byte
    hResult = BCryptExportKey(hKeyPair, 0, StrPtr("ECCPRIVATEBLOB"), VarPtr(baBlob(0)), UBound(baBlob) + 1, cbResult, 0)
    If hResult < 0 Then
        sApiSource = "BCryptExportKey(ECCPRIVATEBLOB)"
        GoTo QH
    End If
    baPriv = pvBCryptFromKeyBlob(baBlob, cbResult)
    hResult = BCryptExportKey(hKeyPair, 0, StrPtr("ECCPUBLICBLOB"), VarPtr(baBlob(0)), UBound(baBlob) + 1, cbResult, 0)
    If hResult < 0 Then
        sApiSource = "BCryptExportKey(ECCPUBLICBLOB)"
        GoTo QH
    End If
    baPub = pvBCryptFromKeyBlob(baBlob, cbResult)
    '--- success
    pvBCryptEcdhP256KeyPair = True
QH:
    If hKeyPair <> 0 Then
        Call BCryptDestroyKey(hKeyPair)
    End If
    If LenB(sApiSource) <> 0 Then
        Err.Raise IIf(hResult < 0, hResult, hResult Or LNG_FACILITY_WIN32), sApiSource
    End If
End Function

Private Function pvBCryptEcdhP256AgreedSecret(baPriv() As Byte, baPub() As Byte) As Byte()
    Dim baRetVal()      As Byte
    Dim hProv           As Long
    Dim hPrivKey        As Long
    Dim hPubKey         As Long
    Dim hAgreedSecret   As Long
    Dim cbAgreedSecret  As Long
    Dim hResult         As Long
    Dim sApiSource      As String
    Dim baBlob()        As Byte
    
    hProv = m_uData.hEcdhP256Prov
    baBlob = pvBCryptToKeyBlob(baPriv)
    hResult = BCryptImportKeyPair(hProv, 0, StrPtr("ECCPRIVATEBLOB"), hPrivKey, VarPtr(baBlob(0)), UBound(baBlob) + 1, 0)
    If hResult < 0 Then
        sApiSource = "BCryptImportKeyPair(ECCPRIVATEBLOB)"
        GoTo QH
    End If
    baBlob = pvBCryptToKeyBlob(baPub)
    hResult = BCryptImportKeyPair(hProv, 0, StrPtr("ECCPUBLICBLOB"), hPubKey, VarPtr(baBlob(0)), UBound(baBlob) + 1, 0)
    If hResult < 0 Then
        sApiSource = "BCryptImportKeyPair(ECCPUBLICBLOB)"
        GoTo QH
    End If
    hResult = BCryptSecretAgreement(hPrivKey, hPubKey, hAgreedSecret, 0)
    If hResult < 0 Then
        sApiSource = "BCryptSecretAgreement"
        GoTo QH
    End If
    ReDim baRetVal(0 To 1023) As Byte
    hResult = BCryptDeriveKey(hAgreedSecret, StrPtr("TRUNCATE"), 0, VarPtr(baRetVal(0)), UBound(baRetVal) + 1, cbAgreedSecret, 0)
    If hResult < 0 Then
        sApiSource = "BCryptDeriveKey"
        GoTo QH
    End If
    ReDim Preserve baRetVal(0 To cbAgreedSecret - 1) As Byte
    pvArrayReverse baRetVal
    pvBCryptEcdhP256AgreedSecret = baRetVal
QH:
    If hAgreedSecret <> 0 Then
        Call BCryptDestroySecret(hAgreedSecret)
    End If
    If hPrivKey <> 0 Then
        Call BCryptDestroyKey(hPrivKey)
    End If
    If hPubKey <> 0 Then
        Call BCryptDestroyKey(hPubKey)
    End If
    If LenB(sApiSource) <> 0 Then
        Err.Raise IIf(hResult < 0, hResult, hResult Or LNG_FACILITY_WIN32), sApiSource
    End If
End Function

Private Function pvBCryptToKeyBlob(baKey() As Byte, Optional ByVal lSize As Long = -1) As Byte()
    Dim baRetVal()      As Byte
    Dim lMagic          As Long
    Dim baUncompr()     As Byte
    Dim lKeyPtr         As Long
    
    If lSize < 0 Then
        lSize = pvArraySize(baKey)
    End If
    If lSize = BCRYPT_SECP256R1_COMPRESSED_PUBLIC_KEYSZ Then
        Debug.Assert baKey(0) = BCRYPT_SECP256R1_TAG_COMPRESSED_POS Or baKey(0) = BCRYPT_SECP256R1_TAG_COMPRESSED_NEG
        lMagic = BCRYPT_ECDH_PUBLIC_P256_MAGIC
        lSize = BCRYPT_SECP256R1_UNCOMPRESSED_PUBLIC_KEYSZ
        ReDim baUncompr(0 To lSize - 1) As Byte
        Call pvCryptoCallSecp256r1UncompressKey(m_uData.Pfn(ucsPfnSecp256r1UncompressKey), baKey(0), baUncompr(0))
        lKeyPtr = VarPtr(baUncompr(1))
        lSize = lSize - 1
    ElseIf lSize = BCRYPT_SECP256R1_UNCOMPRESSED_PUBLIC_KEYSZ Then
        Debug.Assert baKey(0) = BCRYPT_SECP256R1_TAG_UNCOMPRESSED
        lMagic = BCRYPT_ECDH_PUBLIC_P256_MAGIC
        lKeyPtr = VarPtr(baKey(1))
        lSize = lSize - 1
    ElseIf lSize = BCRYPT_SECP256R1_PRIVATE_KEYSZ Then
        lMagic = BCRYPT_ECDH_PRIVATE_P256_MAGIC
        lKeyPtr = VarPtr(baKey(0))
    Else
        Err.Raise vbObjectError, "pvBCryptToKeyBlob", "Unrecognized key size"
    End If
    ReDim baRetVal(0 To 8 + lSize - 1) As Byte
    Call CopyMemory(baRetVal(0), lMagic, 4)
    Call CopyMemory(baRetVal(4), BCRYPT_SECP256R1_PARTSZ, 4)
    Call CopyMemory(baRetVal(8), ByVal lKeyPtr, lSize)
    pvBCryptToKeyBlob = baRetVal
End Function

Private Function pvBCryptFromKeyBlob(baBlob() As Byte, Optional ByVal lSize As Long = -1) As Byte()
    Dim baRetVal()      As Byte
    Dim lMagic          As Long
    Dim lPartSize       As Long
    
    If lSize < 0 Then
        lSize = pvArraySize(baBlob)
    End If
    Call CopyMemory(lMagic, baBlob(0), 4)
    Select Case lMagic
    Case BCRYPT_ECDH_PUBLIC_P256_MAGIC
        Call CopyMemory(lPartSize, baBlob(4), 4)
        Debug.Assert lPartSize = 32
        ReDim baRetVal(0 To BCRYPT_SECP256R1_UNCOMPRESSED_PUBLIC_KEYSZ - 1) As Byte
        Debug.Assert lSize >= 8 + 2 * lPartSize
        baRetVal(0) = BCRYPT_SECP256R1_TAG_UNCOMPRESSED
        Call CopyMemory(baRetVal(1), baBlob(8), 2 * lPartSize)
    Case BCRYPT_ECDH_PRIVATE_P256_MAGIC
        Call CopyMemory(lPartSize, baBlob(4), 4)
        Debug.Assert lPartSize = 32
        ReDim baRetVal(0 To BCRYPT_SECP256R1_PRIVATE_KEYSZ - 1) As Byte
        Debug.Assert lSize >= 8 + 3 * lPartSize
        Call CopyMemory(baRetVal(0), baBlob(8), 3 * lPartSize)
    Case Else
        Err.Raise vbObjectError, "pvBCryptFromKeyBlob", "Unknown BCrypt magic"
    End Select
    pvBCryptFromKeyBlob = baRetVal
End Function
#End If

'= trampolines ===========================================================

Private Function pvCryptoCallSecp256r1MakeKey(ByVal Pfn As Long, pPubKeyPtr As Byte, pPrivKeyPtr As Byte) As Long
    ' int ecc_make_key(uint8_t p_publicKey[ECC_BYTES+1], uint8_t p_privateKey[ECC_BYTES]);
End Function

Private Function pvCryptoCallSecp256r1SharedSecret(ByVal Pfn As Long, pPubKeyPtr As Byte, pPrivKeyPtr As Byte, pSecretPtr As Byte) As Long
    ' int ecdh_shared_secret(const uint8_t p_publicKey[ECC_BYTES+1], const uint8_t p_privateKey[ECC_BYTES], uint8_t p_secret[ECC_BYTES]);
End Function

Private Function pvCryptoCallSecp256r1UncompressKey(ByVal Pfn As Long, pPubKeyPtr As Byte, pUncompressedKeyPtr As Byte) As Long
    ' int ecdh_uncompress_key(const uint8_t p_publicKey[ECC_BYTES + 1], uint8_t p_uncompressedKey[2 * ECC_BYTES + 1])
End Function

Private Function pvCryptoCallCurve25519Multiply(ByVal Pfn As Long, pSecretPtr As Byte, pPubKeyPtr As Byte, pPrivKeyPtr As Byte) As Long
    ' void cf_curve25519_mul(uint8_t out[32], const uint8_t priv[32], const uint8_t pub[32])
End Function

Private Function pvCryptoCallCurve25519MulBase(ByVal Pfn As Long, pPubKeyPtr As Byte, pPrivKeyPtr As Byte) As Long
    ' void cf_curve25519_mul_base(uint8_t out[32], const uint8_t priv[32])
End Function

Private Function pvCryptoCallSha256Init(ByVal Pfn As Long, ByVal lCtxPtr As Long) As Long
    ' void cf_sha256_init(cf_sha256_context *ctx)
End Function

Private Function pvCryptoCallSha256Update(ByVal Pfn As Long, ByVal lCtxPtr As Long, ByVal lDataPtr As Long, ByVal lSize As Long) As Long
    ' void cf_sha256_update(cf_sha256_context *ctx, const void *data, size_t nbytes)
End Function

Private Function pvCryptoCallSha256Final(ByVal Pfn As Long, ByVal lCtxPtr As Long, pHashPtr As Byte) As Long
    ' void cf_sha256_digest_final(cf_sha256_context *ctx, uint8_t hash[LNG_SHA256_HASHSZ])
End Function

Private Function pvCryptoCallSha384Init(ByVal Pfn As Long, ByVal lCtxPtr As Long) As Long
    ' void cf_sha384_init(cf_sha384_context *ctx)
End Function

Private Function pvCryptoCallSha384Update(ByVal Pfn As Long, ByVal lCtxPtr As Long, ByVal lDataPtr As Long, ByVal lSize As Long) As Long
    ' void cf_sha384_update(cf_sha384_context *ctx, const void *data, size_t nbytes)
End Function

Private Function pvCryptoCallSha384Final(ByVal Pfn As Long, ByVal lCtxPtr As Long, pHashPtr As Byte) As Long
    ' void cf_sha384_digest_final(cf_sha384_context *ctx, uint8_t hash[LNG_SHA384_HASHSZ])
End Function

Private Function pvCryptoCallChacha20Poly1305Encrypt( _
            ByVal Pfn As Long, pKeyPtr As Byte, pNoncePtr As Byte, _
            ByVal lHeaderPtr As Long, ByVal lHeaderSize As Long, _
            pPlaintTextPtr As Byte, ByVal lPlaintTextSize As Long, _
            pCipherTextPtr As Byte, pTagPtr As Byte) As Long
    ' void cf_chacha20poly1305_encrypt(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *header, size_t nheader,
    '                                  const uint8_t *plaintext, size_t nbytes, uint8_t *ciphertext, uint8_t tag[16])
End Function

Private Function pvCryptoCallChacha20Poly1305Decrypt( _
            ByVal Pfn As Long, pKeyPtr As Byte, pNoncePtr As Byte, _
            pHeaderPtr As Byte, ByVal lHeaderSize As Long, _
            pCipherTextPtr As Byte, ByVal lCipherTextSize As Long, _
            pTagPtr As Byte, pPlaintTextPtr As Byte) As Long
    ' int cf_chacha20poly1305_decrypt(const uint8_t key[32], const uint8_t nonce[12], const uint8_t *header, size_t nheader,
    '                                 const uint8_t *ciphertext, size_t nbytes, const uint8_t tag[16], uint8_t *plaintext)
End Function

Private Function pvCryptoCallAesGcmEncrypt( _
            ByVal Pfn As Long, pCipherTextPtr As Byte, pTagPtr As Byte, pPlaintTextPtr As Byte, ByVal lPlaintTextSize As Long, _
            ByVal lHeaderPtr As Long, ByVal lHeaderSize As Long, pNoncePtr As Byte, pKeyPtr As Byte, ByVal lKeySize As Long) As Long
    ' void cf_aesgcm_encrypt(uint8_t *c, uint8_t *mac, const uint8_t *m, const size_t mlen, const uint8_t *ad, const size_t adlen,
    '                        const uint8_t *npub, const uint8_t *k, size_t klen)
End Function

Private Function pvCryptoCallAesGcmDecrypt( _
            ByVal Pfn As Long, pPlaintTextPtr As Byte, pCipherTextPtr As Byte, ByVal lCipherTextSize As Long, pTagPtr As Byte, _
            pHeaderPtr As Byte, ByVal lHeaderSize As Long, pNoncePtr As Byte, pKeyPtr As Byte, ByVal lKeySize As Long) As Long
    ' void cf_aesgcm_decrypt(uint8_t *m, const uint8_t *c, const size_t clen, const uint8_t *mac, const uint8_t *ad, const size_t adlen,
    '                        const uint8_t *npub, const uint8_t *k, const size_t klen)
End Function

Private Function pvCryptoCallCollectionItem(ByVal oCol As Collection, Index As Variant, Optional RetVal As Variant) As Long
    Const IDX_COLLECTION_ITEM As Long = 7
    
    pvPatchMethodTrampoline AddressOf mdTlsCrypto.pvCryptoCallCollectionItem, IDX_COLLECTION_ITEM
    pvCryptoCallCollectionItem = pvCryptoCallCollectionItem(oCol, Index, RetVal)
End Function
