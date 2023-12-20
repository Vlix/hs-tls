{-# LANGUAGE OverloadedStrings #-}

module HandshakeSpec where

import Control.Concurrent
import Control.Monad
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Default.Class
import Data.IORef
import Data.List
import Data.Maybe
import Data.X509 (ExtKeyUsageFlag (..))
import Network.TLS
import Network.TLS.Extra.Cipher
import Network.TLS.Internal
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck

import Arbitrary
import PipeChan
import Run

spec :: Spec
spec = do
    describe "pipe" $ do
        it "can setup a channel" pipe_work
    describe "handshake" $ do
        prop "can run TLS 1.2" handshake_simple
        prop "can run TLS 1.3" handshake13_simple
        prop "can update key for TLS 1.3" handshake_update_key
        prop "can prevent downgrade attack" handshake13_downgrade
        prop "can negotiate hash and signature" handshake_hashsignatures
        prop "can negotiate cipher suite" handshake_ciphersuites
        prop "can negotiate group" handshake_groups
        prop "can negotiate elliptic curve" handshake_ec
        prop "can fallback for certificate with cipher" handshake_cert_fallback_cipher
        prop
            "can fallback for certificate with hash and signature"
            handshake_cert_fallback_hs
        prop "can handle server key usage" handshake_server_key_usage
        prop "can handle client key usage" handshake_client_key_usage
        prop "can authenticate client" handshake_client_auth
        prop "can handle extended master secret" handshake_ems
        prop "can resume with extended master secret" handshake_resumption_ems
        prop "can handle ALPN" handshake_alpn
        prop "can handle SNI" handshake_sni
        prop "can re-negotiate with TLS 1.2" handshake12_renegotiation
        prop "can resume session with TLS 1.2" handshake12_session_resumption
        prop "can resume session ticket with TLS 1.2" handshake12_session_ticket
        prop "can handshake with TLS 1.3 Full" handshake13_full
        prop "can handshake with TLS 1.3 HRR" handshake13_hrr
        prop "can handshake with TLS 1.3 PSK" handshake13_psk
        prop "can handshake with TLS 1.3 PSK ticket" handshake13_psk_ticket
        prop "can handshake with TLS 1.3 PSK -> HRR" handshake13_psk_fallback
        prop "can handshake with TLS 1.3 RTT0" handshake13_rtt0
        prop "can handshake with TLS 1.3 RTT0 -> PSK" handshake13_rtt0_fallback
        prop "can handshake with TLS 1.3 RTT0 length" handshake13_rtt0_length
        prop "can handshake with TLS 1.3 EE" handshake13_ee_groups
        prop "can handshake with TLS 1.3 EC groups" handshake13_ec
        prop "can handshake with TLS 1.3 FFDHE groups" handshake13_ffdhe
        prop "can handshake with TLS 1.3 Post-handshake auth" post_handshake_auth

--------------------------------------------------------------

pipe_work :: IO ()
pipe_work = do
    pipe <- newPipe
    _ <- runPipe pipe

    let bSize = 16
    n <- generate (choose (1, 32))

    let d1 = B.replicate (bSize * n) 40
    let d2 = B.replicate (bSize * n) 45

    d1' <- writePipeA pipe d1 >> readPipeB pipe (B.length d1)
    d1' `shouldBe` d1

    d2' <- writePipeB pipe d2 >> readPipeA pipe (B.length d2)
    d2' `shouldBe` d2

--------------------------------------------------------------

handshake_simple :: (ClientParams, ServerParams) -> IO ()
handshake_simple = runTLSPipeSimple

--------------------------------------------------------------

newtype CSP13 = CSP13 (ClientParams, ServerParams) deriving (Show)

instance Arbitrary CSP13 where
    arbitrary = CSP13 <$> arbitraryPairParams13

handshake13_simple :: CSP13 -> IO ()
handshake13_simple (CSP13 params) = runTLSPipeSimple13 params hs Nothing
  where
    cgrps = supportedGroups $ clientSupported $ fst params
    sgrps = supportedGroups $ serverSupported $ snd params
    hs = if head cgrps `elem` sgrps then FullHandshake else HelloRetryRequest

--------------------------------------------------------------

handshake13_downgrade :: (ClientParams, ServerParams) -> IO ()
handshake13_downgrade (cparam, sparam) = do
    versionForced <-
        generate $ elements (supportedVersions $ clientSupported cparam)
    let debug' = (serverDebug sparam){debugVersionForced = Just versionForced}
        sparam' = sparam{serverDebug = debug'}
        params = (cparam, sparam')
        downgraded =
            (isVersionEnabled TLS13 params && versionForced < TLS13)
                || (isVersionEnabled TLS12 params && versionForced < TLS12)
    if downgraded
        then runTLSInitFailure params
        else runTLSPipeSimple params

handshake_update_key :: (ClientParams, ServerParams) -> IO ()
handshake_update_key = runTLSPipeSimpleKeyUpdate

--------------------------------------------------------------

handshake_hashsignatures
    :: ([HashAndSignatureAlgorithm], [HashAndSignatureAlgorithm]) -> IO ()
handshake_hashsignatures (clientHashSigs, serverHashSigs) = do
    tls13 <- generate arbitrary
    let version = if tls13 then TLS13 else TLS12
        ciphers =
            [ cipher_ECDHE_RSA_AES256GCM_SHA384
            , cipher_ECDHE_ECDSA_AES256GCM_SHA384
            , cipher_TLS13_AES128GCM_SHA256
            ]
    (clientParam, serverParam) <-
        generate $
            arbitraryPairParamsWithVersionsAndCiphers
                ([version], [version])
                (ciphers, ciphers)
    let clientParam' =
            clientParam
                { clientSupported =
                    (clientSupported clientParam)
                        { supportedHashSignatures = clientHashSigs
                        }
                }
        serverParam' =
            serverParam
                { serverSupported =
                    (serverSupported serverParam)
                        { supportedHashSignatures = serverHashSigs
                        }
                }
        commonHashSigs = clientHashSigs `intersect` serverHashSigs
        shouldFail
            | tls13 = all incompatibleWithDefaultCurve commonHashSigs
            | otherwise = null commonHashSigs
    if shouldFail
        then runTLSInitFailure (clientParam', serverParam')
        else runTLSPipeSimple (clientParam', serverParam')
  where
    incompatibleWithDefaultCurve (h, SignatureECDSA) = h /= HashSHA256
    incompatibleWithDefaultCurve _ = False

handshake_ciphersuites :: ([Cipher], [Cipher]) -> IO ()
handshake_ciphersuites (clientCiphers, serverCiphers) = do
    tls13 <- generate arbitrary
    let version = if tls13 then TLS13 else TLS12
    (clientParam, serverParam) <-
        generate $
            arbitraryPairParamsWithVersionsAndCiphers
                ([version], [version])
                (clientCiphers, serverCiphers)
    let adequate = cipherAllowedForVersion version
        shouldSucceed = any adequate (clientCiphers `intersect` serverCiphers)
    if shouldSucceed
        then runTLSPipeSimple (clientParam, serverParam)
        else runTLSInitFailure (clientParam, serverParam)

--------------------------------------------------------------

handshake_groups :: GGP -> IO ()
handshake_groups (GGP clientGroups serverGroups) = do
    tls13 <- generate arbitrary
    let versions = if tls13 then [TLS13] else [TLS12]
        ciphers = ciphersuite_strong
    (clientParam, serverParam) <-
        generate $
            arbitraryPairParamsWithVersionsAndCiphers
                (versions, versions)
                (ciphers, ciphers)
    denyCustom <- generate arbitrary
    let groupUsage =
            if denyCustom
                then GroupUsageUnsupported "custom group denied"
                else GroupUsageValid
        clientParam' =
            clientParam
                { clientSupported =
                    (clientSupported clientParam)
                        { supportedGroups = clientGroups
                        }
                , clientHooks =
                    (clientHooks clientParam)
                        { onCustomFFDHEGroup = \_ _ -> return groupUsage
                        }
                }
        serverParam' =
            serverParam
                { serverSupported =
                    (serverSupported serverParam)
                        { supportedGroups = serverGroups
                        }
                }
        commonGroups = clientGroups `intersect` serverGroups
        shouldFail = null commonGroups
        p minfo = isNothing (minfo >>= infoSupportedGroup) == (null commonGroups)
    if shouldFail
        then runTLSInitFailure (clientParam', serverParam')
        else runTLSPipePredicate (clientParam', serverParam') p

--------------------------------------------------------------

newtype SG = SG [Group] deriving (Show)

instance Arbitrary SG where
    arbitrary = SG <$> shuffle sigGroups
      where
        sigGroups = [P256, P521]

handshake_ec :: SG -> IO ()
handshake_ec (SG sigGroups) = do
    let versions = [TLS12]
        ciphers =
            [ cipher_ECDHE_ECDSA_AES256GCM_SHA384
            ]
        hashSignatures =
            [ (HashSHA256, SignatureECDSA)
            ]
    (clientParam, serverParam) <-
        generate $
            arbitraryPairParamsWithVersionsAndCiphers
                (versions, versions)
                (ciphers, ciphers)
    clientGroups <- generate $ shuffle sigGroups
    clientHashSignatures <- generate $ sublistOf hashSignatures
    serverHashSignatures <- generate $ sublistOf hashSignatures
    credentials <- generate arbitraryCredentialsOfEachCurve
    let clientParam' =
            clientParam
                { clientSupported =
                    (clientSupported clientParam)
                        { supportedGroups = clientGroups
                        , supportedHashSignatures = clientHashSignatures
                        }
                }
        serverParam' =
            serverParam
                { serverSupported =
                    (serverSupported serverParam)
                        { supportedGroups = sigGroups
                        , supportedHashSignatures = serverHashSignatures
                        }
                , serverShared =
                    (serverShared serverParam)
                        { sharedCredentials = Credentials credentials
                        }
                }
        sigAlgs = map snd (clientHashSignatures `intersect` serverHashSignatures)
        ecdsaDenied = SignatureECDSA `notElem` sigAlgs
    if ecdsaDenied
        then runTLSInitFailure (clientParam', serverParam')
        else runTLSPipeSimple (clientParam', serverParam')

-- Tests ability to use or ignore client "signature_algorithms" extension when
-- choosing a server certificate.  Here peers allow DHE_RSA_AES128_SHA1 but
-- the server RSA certificate has a SHA-1 signature that the client does not
-- support.  Server may choose the DSA certificate only when cipher
-- DHE_DSA_AES128_SHA1 is allowed.  Otherwise it must fallback to the RSA
-- certificate.

data OC = OC [Cipher] [Cipher] deriving (Show)

instance Arbitrary OC where
    arbitrary = OC <$> sublistOf otherCiphers <*> sublistOf otherCiphers
      where
        otherCiphers =
            [ cipher_ECDHE_RSA_AES256GCM_SHA384
            , cipher_ECDHE_RSA_AES128GCM_SHA256
            ]

handshake_cert_fallback_cipher :: OC -> IO ()
handshake_cert_fallback_cipher (OC clientCiphers serverCiphers) = do
    let clientVersions = [TLS12]
        serverVersions = [TLS12]
        commonCiphers = [cipher_ECDHE_RSA_AES128GCM_SHA256]
        hashSignatures = [(HashSHA256, SignatureRSA), (HashSHA1, SignatureDSA)]
    chainRef <- newIORef Nothing
    (clientParam, serverParam) <-
        generate $
            arbitraryPairParamsWithVersionsAndCiphers
                (clientVersions, serverVersions)
                (clientCiphers ++ commonCiphers, serverCiphers ++ commonCiphers)
    let clientParam' =
            clientParam
                { clientSupported =
                    (clientSupported clientParam)
                        { supportedHashSignatures = hashSignatures
                        }
                , clientHooks =
                    (clientHooks clientParam)
                        { onServerCertificate = \_ _ _ chain ->
                            writeIORef chainRef (Just chain) >> return []
                        }
                }
    runTLSPipeSimple (clientParam', serverParam)
    serverChain <- readIORef chainRef
    isLeafRSA serverChain `shouldBe` True

-- Same as above but testing with supportedHashSignatures directly instead of
-- ciphers, and thus allowing TLS13.  Peers accept RSA with SHA-256 but the
-- server RSA certificate has a SHA-1 signature.  When Ed25519 is allowed by
-- both client and server, the Ed25519 certificate is selected.  Otherwise the
-- server fallbacks to RSA.
--
-- Note: SHA-1 is supposed to be disallowed in X.509 signatures with TLS13
-- unless client advertises explicit support.  Currently this is not enforced by
-- the library, which is useful to test this scenario.  SHA-1 could be replaced
-- by another algorithm.

data OHS = OHS [HashAndSignatureAlgorithm] [HashAndSignatureAlgorithm]
    deriving (Show)

instance Arbitrary OHS where
    arbitrary = OHS <$> sublistOf otherHS <*> sublistOf otherHS
      where
        otherHS = [(HashIntrinsic, SignatureEd25519)]

handshake_cert_fallback_hs :: OHS -> IO ()
handshake_cert_fallback_hs (OHS clientHS serverHS) = do
    tls13 <- generate arbitrary
    let versions = if tls13 then [TLS13] else [TLS12]
        ciphers =
            [ cipher_ECDHE_RSA_AES128GCM_SHA256
            , cipher_ECDHE_ECDSA_AES128GCM_SHA256
            , cipher_TLS13_AES128GCM_SHA256
            ]
        commonHS =
            [ (HashSHA256, SignatureRSA)
            , (HashIntrinsic, SignatureRSApssRSAeSHA256)
            ]
    chainRef <- newIORef Nothing
    (clientParam, serverParam) <-
        generate $
            arbitraryPairParamsWithVersionsAndCiphers
                (versions, versions)
                (ciphers, ciphers)
    let clientParam' =
            clientParam
                { clientSupported =
                    (clientSupported clientParam)
                        { supportedHashSignatures = commonHS ++ clientHS
                        }
                , clientHooks =
                    (clientHooks clientParam)
                        { onServerCertificate = \_ _ _ chain ->
                            writeIORef chainRef (Just chain) >> return []
                        }
                }
        serverParam' =
            serverParam
                { serverSupported =
                    (serverSupported serverParam)
                        { supportedHashSignatures = commonHS ++ serverHS
                        }
                }
        eddsaDisallowed =
            (HashIntrinsic, SignatureEd25519) `notElem` clientHS
                || (HashIntrinsic, SignatureEd25519) `notElem` serverHS
    runTLSPipeSimple (clientParam', serverParam')
    serverChain <- readIORef chainRef
    isLeafRSA serverChain `shouldBe` eddsaDisallowed

--------------------------------------------------------------

handshake_server_key_usage :: [ExtKeyUsageFlag] -> IO ()
handshake_server_key_usage usageFlags = do
    tls13 <- generate arbitrary
    let versions = if tls13 then [TLS13] else [TLS12]
        ciphers = ciphersuite_all
    (clientParam, serverParam) <-
        generate $
            arbitraryPairParamsWithVersionsAndCiphers
                (versions, versions)
                (ciphers, ciphers)
    cred <- generate $ arbitraryRSACredentialWithUsage usageFlags
    let serverParam' =
            serverParam
                { serverShared =
                    (serverShared serverParam)
                        { sharedCredentials = Credentials [cred]
                        }
                }
        shouldSucceed = KeyUsage_digitalSignature `elem` usageFlags
    if shouldSucceed
        then runTLSPipeSimple (clientParam, serverParam')
        else runTLSInitFailure (clientParam, serverParam')

handshake_client_key_usage :: [ExtKeyUsageFlag] -> IO ()
handshake_client_key_usage usageFlags = do
    (clientParam, serverParam) <- generate arbitrary
    cred <- generate $ arbitraryRSACredentialWithUsage usageFlags
    let clientParam' =
            clientParam
                { clientHooks =
                    (clientHooks clientParam)
                        { onCertificateRequest = \_ -> return $ Just cred
                        }
                }
        serverParam' =
            serverParam
                { serverWantClientCert = True
                , serverHooks =
                    (serverHooks serverParam)
                        { onClientCertificate = \_ -> return CertificateUsageAccept
                        }
                }
        shouldSucceed = KeyUsage_digitalSignature `elem` usageFlags
    if shouldSucceed
        then runTLSPipeSimple (clientParam', serverParam')
        else runTLSInitFailure (clientParam', serverParam')

--------------------------------------------------------------

handshake_client_auth :: (ClientParams, ServerParams) -> IO ()
handshake_client_auth (clientParam, serverParam) = do
    let clientVersions = supportedVersions $ clientSupported clientParam
        serverVersions = supportedVersions $ serverSupported serverParam
        version = maximum (clientVersions `intersect` serverVersions)
    cred <- generate (arbitraryClientCredential version)
    let clientParam' =
            clientParam
                { clientHooks =
                    (clientHooks clientParam)
                        { onCertificateRequest = \_ -> return $ Just cred
                        }
                }
        serverParam' =
            serverParam
                { serverWantClientCert = True
                , serverHooks =
                    (serverHooks serverParam)
                        { onClientCertificate = validateChain cred
                        }
                }
    let shouldFail = version == TLS13 && isCredentialDSA cred
    if shouldFail
        then runTLSInitFailure (clientParam', serverParam')
        else runTLSPipeSimple (clientParam', serverParam')
  where
    validateChain cred chain
        | chain == fst cred = return CertificateUsageAccept
        | otherwise = return (CertificateUsageReject CertificateRejectUnknownCA)

--------------------------------------------------------------

handshake_ems :: (EMSMode, EMSMode) -> IO ()
handshake_ems (cems, sems) = do
    params <- generate arbitrary
    let params' = setEMSMode (cems, sems) params
        version = getConnectVersion params'
        emsVersion = version >= TLS10 && version <= TLS12
        use = cems /= NoEMS && sems /= NoEMS
        require = cems == RequireEMS || sems == RequireEMS
        p info = infoExtendedMasterSec info == (emsVersion && use)
    if emsVersion && require && not use
        then runTLSInitFailure params'
        else runTLSPipePredicate params' (maybe False p)

newtype CompatEMS = CompatEMS (EMSMode, EMSMode) deriving (Show)

instance Arbitrary CompatEMS where
    arbitrary = CompatEMS <$> (arbitrary `suchThat` compatible)
      where
        compatible (NoEMS, RequireEMS) = False
        compatible (RequireEMS, NoEMS) = False
        compatible _ = True

handshake_resumption_ems :: (CompatEMS, CompatEMS) -> IO ()
handshake_resumption_ems (CompatEMS ems, CompatEMS ems2) = do
    sessionRefs <- twoSessionRefs
    let sessionManagers = twoSessionManagers sessionRefs

    plainParams <- generate arbitrary
    let params =
            setEMSMode ems $
                setPairParamsSessionManagers sessionManagers plainParams

    runTLSPipeSimple params

    -- and resume
    sessionParams <- readClientSessionRef sessionRefs
    sessionParams `shouldSatisfy` isJust
    let params2 =
            setEMSMode ems2 $
                setPairParamsSessionResuming (fromJust sessionParams) params

    let version = getConnectVersion params2
        emsVersion = version >= TLS10 && version <= TLS12

    if emsVersion && use ems && not (use ems2)
        then runTLSInitFailure params2
        else do
            runTLSPipeSimple params2
            sessionParams2 <- readClientSessionRef sessionRefs
            let sameSession = sessionParams == sessionParams2
                sameUse = use ems == use ems2
            when emsVersion $ (sameSession `shouldBe` sameUse)
  where
    use (NoEMS, _) = False
    use (_, NoEMS) = False
    use _ = True

--------------------------------------------------------------

handshake_alpn :: (ClientParams, ServerParams) -> IO ()
handshake_alpn (clientParam, serverParam) = do
    let clientParam' =
            clientParam
                { clientHooks =
                    (clientHooks clientParam)
                        { onSuggestALPN = return $ Just ["h2", "http/1.1"]
                        }
                }
        serverParam' =
            serverParam
                { serverHooks =
                    (serverHooks serverParam)
                        { onALPNClientSuggest = Just alpn
                        }
                }
        params' = (clientParam', serverParam')
    runTLSPipe params' tlsServer tlsClient
  where
    tlsServer ctx queue = do
        handshake ctx
        checkCtxFinished ctx
        proto <- getNegotiatedProtocol ctx
        proto `shouldBe` Just "h2"
        d <- recvData ctx
        writeChan queue [d]
        bye ctx
    tlsClient queue ctx = do
        handshake ctx
        checkCtxFinished ctx
        proto <- getNegotiatedProtocol ctx
        proto `shouldBe` Just "h2"
        d <- readChan queue
        sendData ctx (L.fromChunks [d])
        byeBye ctx
    alpn xs
        | "h2" `elem` xs = return "h2"
        | otherwise = return "http/1.1"

handshake_sni :: (ClientParams, ServerParams) -> IO ()
handshake_sni (clientParam, serverParam) = do
    ref <- newIORef Nothing
    let clientParam' =
            clientParam
                { clientServerIdentification = (serverName, "")
                }
        serverParam' =
            serverParam
                { serverHooks =
                    (serverHooks serverParam)
                        { onServerNameIndication = onSNI ref
                        }
                }
        params' = (clientParam', serverParam')
    runTLSPipe params' tlsServer tlsClient
    receivedName <- readIORef ref
    receivedName `shouldBe` Just (Just serverName)
  where
    tlsServer ctx queue = do
        handshake ctx
        checkCtxFinished ctx
        sni <- getClientSNI ctx
        sni `shouldBe` Just serverName
        d <- recvData ctx
        writeChan queue [d]
        bye ctx
    tlsClient queue ctx = do
        handshake ctx
        checkCtxFinished ctx
        sni <- getClientSNI ctx
        sni `shouldBe` Just serverName
        d <- readChan queue
        sendData ctx (L.fromChunks [d])
        byeBye ctx
    onSNI ref name = do
        mx <- readIORef ref
        mx `shouldBe` Nothing
        writeIORef ref (Just name)
        return (Credentials [])
    serverName = "haskell.org"

--------------------------------------------------------------

newtype CSP12 = CSP12 (ClientParams, ServerParams) deriving (Show)

instance Arbitrary CSP12 where
    arbitrary = CSP12 <$> arbitraryPairParams12

handshake12_renegotiation :: CSP12 -> IO ()
handshake12_renegotiation (CSP12 (cparams, sparams)) = do
    renegDisabled <- generate arbitrary
    let sparams' =
            sparams
                { serverSupported =
                    (serverSupported sparams)
                        { supportedClientInitiatedRenegotiation = not renegDisabled
                        }
                }
    if renegDisabled
        then runTLSInitFailureGen (cparams, sparams') hsServer hsClient
        else runTLSPipe (cparams, sparams') tlsServer tlsClient
  where
    tlsServer ctx queue = do
        hsServer ctx
        checkCtxFinished ctx
        d <- recvData ctx
        writeChan queue [d]
        bye ctx
    tlsClient queue ctx = do
        hsClient ctx
        checkCtxFinished ctx
        d <- readChan queue
        sendData ctx (L.fromChunks [d])
        byeBye ctx
    hsServer = handshake
    hsClient ctx = handshake ctx >> handshake ctx

handshake12_session_resumption :: CSP12 -> IO ()
handshake12_session_resumption (CSP12 plainParams) = do
    sessionRefs <- twoSessionRefs
    let sessionManagers = twoSessionManagers sessionRefs

    let params = setPairParamsSessionManagers sessionManagers plainParams

    runTLSPipeSimple params

    -- and resume
    sessionParams <- readClientSessionRef sessionRefs
    sessionParams `shouldSatisfy` isJust
    let params2 = setPairParamsSessionResuming (fromJust sessionParams) params

    runTLSPipePredicate params2 (maybe False infoTLS12Resumption)

handshake12_session_ticket :: CSP12 -> IO ()
handshake12_session_ticket (CSP12 plainParams) = do
    sessionRefs <- twoSessionRefs
    let sessionManagers0 = twoSessionManagers sessionRefs
        sessionManagers = (fst sessionManagers0, oneSessionTicket)

    let params = setPairParamsSessionManagers sessionManagers plainParams

    runTLSPipeSimple params

    -- and resume
    sessionParams <- readClientSessionRef sessionRefs
    sessionParams `shouldSatisfy` isJust
    let params2 = setPairParamsSessionResuming (fromJust sessionParams) params

    runTLSPipePredicate params2 (maybe False infoTLS12Resumption)

--------------------------------------------------------------

handshake13_full :: CSP13 -> IO ()
handshake13_full (CSP13 (cli, srv)) = do
    let cliSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [X25519]
                }
        svrSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [X25519]
                }
        params =
            ( cli{clientSupported = cliSupported}
            , srv{serverSupported = svrSupported}
            )
    runTLSPipeSimple13 params FullHandshake Nothing

handshake13_hrr :: CSP13 -> IO ()
handshake13_hrr (CSP13 (cli, srv)) = do
    let cliSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [P256, X25519]
                }
        svrSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [X25519]
                }
        params =
            ( cli{clientSupported = cliSupported}
            , srv{serverSupported = svrSupported}
            )
    runTLSPipeSimple13 params HelloRetryRequest Nothing

handshake13_psk :: CSP13 -> IO ()
handshake13_psk (CSP13 (cli, srv)) = do
    let cliSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [P256, X25519]
                }
        svrSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [X25519]
                }
        params0 =
            ( cli{clientSupported = cliSupported}
            , srv{serverSupported = svrSupported}
            )

    sessionRefs <- twoSessionRefs
    let sessionManagers = twoSessionManagers sessionRefs

    let params = setPairParamsSessionManagers sessionManagers params0

    runTLSPipeSimple13 params HelloRetryRequest Nothing

    -- and resume
    sessionParams <- readClientSessionRef sessionRefs
    sessionParams `shouldSatisfy` isJust
    let params2 = setPairParamsSessionResuming (fromJust sessionParams) params

    runTLSPipeSimple13 params2 PreSharedKey Nothing

handshake13_psk_ticket :: CSP13 -> IO ()
handshake13_psk_ticket (CSP13 (cli, srv)) = do
    let cliSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [P256, X25519]
                }
        svrSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [X25519]
                }
        params0 =
            ( cli{clientSupported = cliSupported}
            , srv{serverSupported = svrSupported}
            )

    sessionRefs <- twoSessionRefs
    let sessionManagers0 = twoSessionManagers sessionRefs
        sessionManagers = (fst sessionManagers0, oneSessionTicket)

    let params = setPairParamsSessionManagers sessionManagers params0

    runTLSPipeSimple13 params HelloRetryRequest Nothing

    -- and resume
    sessionParams <- readClientSessionRef sessionRefs
    sessionParams `shouldSatisfy` isJust
    let params2 = setPairParamsSessionResuming (fromJust sessionParams) params

    runTLSPipeSimple13 params2 PreSharedKey Nothing

handshake13_psk_fallback :: CSP13 -> IO ()
handshake13_psk_fallback (CSP13 (cli, srv)) = do
    let cliSupported =
            def
                { supportedCiphers =
                    [ cipher_TLS13_AES128GCM_SHA256
                    , cipher_TLS13_AES128CCM_SHA256
                    ]
                , supportedGroups = [P256, X25519]
                }
        svrSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [X25519]
                }
        params0 =
            ( cli{clientSupported = cliSupported}
            , srv{serverSupported = svrSupported}
            )

    sessionRefs <- twoSessionRefs
    let sessionManagers = twoSessionManagers sessionRefs

    let params = setPairParamsSessionManagers sessionManagers params0

    runTLSPipeSimple13 params HelloRetryRequest Nothing

    -- resumption fails because GCM cipher is not supported anymore, full
    -- handshake is not possible because X25519 has been removed, so we are
    -- back with P256 after hello retry
    sessionParams <- readClientSessionRef sessionRefs
    sessionParams `shouldSatisfy` isJust
    let (cli2, srv2) = setPairParamsSessionResuming (fromJust sessionParams) params
        srv2' = srv2{serverSupported = svrSupported'}
        svrSupported' =
            def
                { supportedCiphers = [cipher_TLS13_AES128CCM_SHA256]
                , supportedGroups = [P256]
                }

    runTLSPipeSimple13 (cli2, srv2') HelloRetryRequest Nothing

handshake13_rtt0 :: CSP13 -> IO ()
handshake13_rtt0 (CSP13 (cli, srv)) = do
    let cliSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [P256, X25519]
                }
        svrSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [X25519]
                }
        cliHooks =
            def
                { onSuggestALPN = return $ Just ["h2"]
                }
        svrHooks =
            def
                { onALPNClientSuggest = Just (\protos -> return $ head protos)
                }
        params0 =
            ( cli
                { clientSupported = cliSupported
                , clientHooks = cliHooks
                }
            , srv
                { serverSupported = svrSupported
                , serverHooks = svrHooks
                , serverEarlyDataSize = 2048
                }
            )

    sessionRefs <- twoSessionRefs
    let sessionManagers = twoSessionManagers sessionRefs

    let params = setPairParamsSessionManagers sessionManagers params0

    runTLSPipeSimple13 params HelloRetryRequest Nothing

    -- and resume
    sessionParams <- readClientSessionRef sessionRefs
    sessionParams `shouldSatisfy` isJust
    earlyData <- B.pack <$> generate (someWords8 256)
    let (pc, ps) = setPairParamsSessionResuming (fromJust sessionParams) params
        params2 = (pc{clientEarlyData = Just earlyData}, ps)

    runTLSPipeSimple13 params2 RTT0 (Just earlyData)

handshake13_rtt0_fallback :: IO ()
handshake13_rtt0_fallback = do
    ticketSize <- generate $ choose (0, 512)
    (cli, srv) <- generate arbitraryPairParams13
    group0 <- generate $ elements [P256, X25519]
    let cliSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [P256, X25519]
                }
        svrSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [group0]
                }
        params0 =
            ( cli{clientSupported = cliSupported}
            , srv
                { serverSupported = svrSupported
                , serverEarlyDataSize = ticketSize
                }
            )

    sessionRefs <- twoSessionRefs
    let sessionManagers = twoSessionManagers sessionRefs

    let params = setPairParamsSessionManagers sessionManagers params0

    let mode = if group0 == P256 then FullHandshake else HelloRetryRequest
    runTLSPipeSimple13 params mode Nothing

    -- and resume
    sessionParams <- readClientSessionRef sessionRefs
    sessionParams `shouldSatisfy` isJust
    earlyData <- B.pack <$> generate (someWords8 256)
    group2 <- generate $ elements [P256, X25519]
    let (pc, ps) = setPairParamsSessionResuming (fromJust sessionParams) params
        svrSupported2 =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [group2]
                }
        params2 =
            ( pc{clientEarlyData = Just earlyData}
            , ps
                { serverEarlyDataSize = 0
                , serverSupported = svrSupported2
                }
            )

    let mode2 = if ticketSize < 256 then PreSharedKey else RTT0
    runTLSPipeSimple13 params2 mode2 Nothing

handshake13_rtt0_length :: CSP13 -> IO ()
handshake13_rtt0_length (CSP13 (cli, srv)) = do
    serverMax <- generate $ choose (0, 33792)
    let cliSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [X25519]
                }
        svrSupported =
            def
                { supportedCiphers = [cipher_TLS13_AES128GCM_SHA256]
                , supportedGroups = [X25519]
                }
        params0 =
            ( cli{clientSupported = cliSupported}
            , srv
                { serverSupported = svrSupported
                , serverEarlyDataSize = serverMax
                }
            )

    sessionRefs <- twoSessionRefs
    let sessionManagers = twoSessionManagers sessionRefs
    let params = setPairParamsSessionManagers sessionManagers params0
    runTLSPipeSimple13 params FullHandshake Nothing

    -- and resume
    sessionParams <- readClientSessionRef sessionRefs
    sessionParams `shouldSatisfy` isJust
    clientLen <- generate $ choose (0, 33792)
    earlyData <- B.pack <$> generate (someWords8 clientLen)
    let (pc, ps) = setPairParamsSessionResuming (fromJust sessionParams) params
        params2 = (pc{clientEarlyData = Just earlyData}, ps)
        (mode, mEarlyData)
            | clientLen > serverMax = (PreSharedKey, Nothing)
            | otherwise = (RTT0, Just earlyData)
    runTLSPipeSimple13 params2 mode mEarlyData

handshake13_ee_groups :: CSP13 -> IO ()
handshake13_ee_groups (CSP13 (cli, srv)) = do
    let -- The client prefers P256
        cliSupported = (clientSupported cli){supportedGroups = [P256, X25519]}
        -- The server prefers X25519
        svrSupported = (serverSupported srv){supportedGroups = [X25519, P256]}
        params =
            ( cli{clientSupported = cliSupported}
            , srv{serverSupported = svrSupported}
            )
    (_, serverMessages) <- runTLSPipeCapture13 params
    -- The server should tell X25519 in supported_groups in EE to clinet
    let isSupportedGroups (ExtensionRaw eid _) = eid == EID_SupportedGroups
        eeMessagesHaveExt =
            [ any isSupportedGroups exts
            | EncryptedExtensions13 exts <- serverMessages
            ]
    eeMessagesHaveExt `shouldBe` [True]

handshake13_ec :: CSP13 -> IO ()
handshake13_ec (CSP13 (cli, srv)) = do
    EC cgrps <- generate arbitrary
    EC sgrps <- generate arbitrary
    let cliSupported = (clientSupported cli){supportedGroups = cgrps}
        svrSupported = (serverSupported srv){supportedGroups = sgrps}
        params =
            ( cli{clientSupported = cliSupported}
            , srv{serverSupported = svrSupported}
            )
    runTLSPipeSimple13 params FullHandshake Nothing

handshake13_ffdhe :: CSP13 -> IO ()
handshake13_ffdhe (CSP13 (cli, srv)) = do
    FFDHE cgrps <- generate arbitrary
    FFDHE sgrps <- generate arbitrary
    let cliSupported = (clientSupported cli){supportedGroups = cgrps}
        svrSupported = (serverSupported srv){supportedGroups = sgrps}
        params =
            ( cli{clientSupported = cliSupported}
            , srv{serverSupported = svrSupported}
            )
    runTLSPipeSimple13 params FullHandshake Nothing

post_handshake_auth :: CSP13 -> IO ()
post_handshake_auth (CSP13 (clientParam, serverParam)) = do
    cred <- generate (arbitraryClientCredential TLS13)
    let clientParam' =
            clientParam
                { clientHooks =
                    (clientHooks clientParam)
                        { onCertificateRequest = \_ -> return $ Just cred
                        }
                }
        serverParam' =
            serverParam
                { serverHooks =
                    (serverHooks serverParam)
                        { onClientCertificate = validateChain cred
                        }
                }
    if isCredentialDSA cred
        then runTLSInitFailureGen (clientParam', serverParam') hsServer hsClient
        else runTLSPipe (clientParam', serverParam') tlsServer tlsClient
  where
    validateChain cred chain
        | chain == fst cred = return CertificateUsageAccept
        | otherwise = return (CertificateUsageReject CertificateRejectUnknownCA)
    tlsServer ctx queue = do
        hsServer ctx
        d <- recvData ctx
        writeChan queue [d]
        bye ctx
    tlsClient queue ctx = do
        hsClient ctx
        d <- readChan queue
        sendData ctx (L.fromChunks [d])
        byeBye ctx
    hsServer ctx = do
        handshake ctx
        checkCtxFinished ctx
        recvDataAssert ctx "request 1"
        _ <- requestCertificate ctx -- single request
        sendData ctx "response 1"
        recvDataAssert ctx "request 2"
        _ <- requestCertificate ctx
        _ <- requestCertificate ctx -- two simultaneously
        sendData ctx "response 2"
    hsClient ctx = do
        handshake ctx
        checkCtxFinished ctx
        sendData ctx "request 1"
        recvDataAssert ctx "response 1"
        sendData ctx "request 2"
        recvDataAssert ctx "response 2"