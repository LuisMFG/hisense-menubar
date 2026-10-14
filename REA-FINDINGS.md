# Engenharia reversa com REA — ConnectLife 2.17.2 (Android)

Alvo: `ConnectLife_2.17.2_APKPure.xapk` (sha256 a83dfe45…a2ba3)
- `rea extract-artifact` → base APK + split `config.armeabi_v7a.apk`
- `rea identify-flutter-build` → Flutter; `libapp.so` sha256 71304283…8d594, snapshot 78da37fed6bf1489361a312568249f3f
- `rea inspect-dart-aot` → pool de strings do snapshot Dart (packages `air_conditioner`, `hi_appliance`, `gigya_flutter_plugin`, classes `RSASigner`, `RSAPublicKey`)
- Varredura completa de strings no `libapp.so` extraído pelo REA

## Confirmado no app oficial
| Item | Valor |
|---|---|
| Login CDC (Gigya) | `https://accounts.eu1.gigya.com/` · `accounts.login` · `getJWT` · API key `4_yhTWQmHFpZkQZDSV1uV-_A` |
| OAuth | `oauth/authorize` · `thirdType` · `thirdClientId` |
| Gateway | `clife-eu-gateway.hijuconn.com` · `get_device_status_list` · `property/set` |
| Assinatura | campos `accessToken appId appSecret languageId randStr timeStamp timezone`; sufixo `D9519A4B756946F081B7BB5B5E8D1197`; RSA |
| Propriedades do AC | `t_power t_temp t_work_mode t_fan_speed t_super f_temp_in t_eco t_sleep t_up_down t_swing_angle t_fan_mute t_temp_type` |

## Não confirmado / diferente
- `appId` do app oficial: `47110563037231`. O `appSecret` e a chave RSA não aparecem em texto puro
  (dex, libs nativas, assets) — provavelmente ofuscados. Usamos o par appId/secret/chave publicado por
  oyvindwe/connectlife, que o gateway aceita (teste com token falso retornou "AccessToken Invalid",
  não erro de assinatura).
