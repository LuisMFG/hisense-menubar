<div align="center">

# Hisense Menubar

**Controle seu ar-condicionado Hisense (ConnectLife) direto da barra de menus do Mac.**

Sem procurar o controle remoto, sem pegar o celular.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white)
![SwiftUI + Metal](https://img.shields.io/badge/SwiftUI-Metal-0A84FF)
![License](https://img.shields.io/badge/license-GPL--3.0-blue)

<img src="docs/hero.png" alt="Painel em modo frio, calor com timer e desumidificar" width="100%">

</div>

## O que faz

- **Temperatura na barra de menus**: `23°` quando está ligado, `off` quando está desligado e um ícone de timer quando há desligamento agendado.
- **Dial de termostato**: arraste o anel, use os botões `−`/`+` ou as setas `↑`/`↓`. O trackpad vibra a cada grau.
- **Split animado**: a aleta abre ao ligar e o fluxo de ar (um shader Metal) desce até o dial, com a cor do modo e a força da ventilação.
- **Modos**: Frio, Calor, Seco, Vento e Auto, cada um com sua cor. O ícone do modo ativo "respira".
- **Ventilação**: medidor de barras com Auto e 5 velocidades. O ícone do ventilador gira na velocidade escolhida.
- **Funções extras**: Turbo, Swing, Eco e Sono. Só aparecem as que o seu modelo informa ter.
- **Timer de desligamento**: 30m, 1h, 2h, 4h ou 8h, com contagem regressiva, `+30m` para adiar e notificação ao desligar.
- **Leve e nativo**: app SwiftUI de ~1 MB que não aparece no Dock e guarda a senha só no Keychain.

| Desligado | Timer ativo |
|:---:|:---:|
| <img src="docs/off.png" width="340"> | <img src="docs/heat.png" width="340"> |

## Instalação

Requisitos: macOS 14 ou mais novo e as Command Line Tools do Xcode (`xcode-select --install`). O Xcode completo não é necessário.

```bash
git clone https://github.com/LuisMFG/hisense-menubar.git
cd hisense-menubar
./build-app.sh
cp -R "build/Ar Condicionado.app" /Applications/
open "/Applications/Ar Condicionado.app"
```

Clique no ícone do ar-condicionado na barra de menus e entre com o **mesmo e-mail e senha do app ConnectLife**.

Para abrir junto com o Mac, adicione o app em **Ajustes do Sistema → Geral → Itens de Início**.

### Atalhos (com o painel aberto)

| Tecla | Ação |
|---|---|
| `Espaço` | Liga/desliga |
| `↑` / `↓` | +1° / −1° |
| `⌘R` | Atualizar status |
| `⌘Q` | Fechar o app |

## Como funciona

A Hisense não publica uma API. O app conversa com a mesma nuvem que o app oficial ConnectLife usa:

```
Gigya (CDC)          OAuth hijuconn            Gateway clife-eu
accounts.login  ──▶  /oauth/authorize    ──▶  /clife-svc/pu/get_device_status_list
accounts.getJWT      /oauth/token              /device/pu/property/set
                                               └─ cada requisição é assinada:
                                                  sign = RSA_PKCS1(SHA256(params ordenados + sufixo))
```

O status chega como propriedades (`t_power`, `t_temp`, `t_work_mode`, `t_fan_speed`, `f_temp_in`…). Os comandos mudam essas mesmas propriedades. O painel atualiza na hora (de forma otimista) e confirma com a nuvem a cada 60 s.

## Engenharia reversa com REA

O protocolo foi verificado contra o app oficial **ConnectLife 2.17.2 (Android)** usando o [REA](https://github.com/morluto/rea), um MCP/CLI de engenharia reversa para agentes:

1. `rea extract-artifact`: extrai o `.xapk` (APK base e o split `armeabi-v7a`).
2. `rea identify-flutter-build`: o app é **Flutter**, então a lógica fica em Dart AOT (`libapp.so`).
3. `rea inspect-dart-aot`: lê o pool de strings do snapshot Dart (módulos `air_conditioner`, `gigya_flutter_plugin`, `RSASigner`…).
4. Varredura do `libapp.so` extraído para confirmar endpoints, campos da assinatura e nomes de propriedades.

O que foi confirmado, o que ficou diferente (o `appId` do app oficial, por exemplo) e o que não deu para extrair (`appSecret` e chave RSA, que estão ofuscados) está em [**REA-FINDINGS.md**](REA-FINDINGS.md).

## Estrutura

```
Sources/ArCondicionado/
├── ConnectLifeAPI.swift   # login Gigya → OAuth → gateway assinado (SHA256 + RSA)
├── ACStore.swift          # estado, comandos otimistas, timer, Keychain
├── Views.swift            # painel: dial, modos, ventilação, chips, timer
├── Effects.swift          # vidro, shader Metal do fluxo de ar, split, háptico
└── App.swift              # MenuBarExtra
Snapshot/                  # gera as imagens do README com dados fictícios
build-app.sh               # compila e empacota o .app
snapshot.sh                # ./snapshot.sh → docs/*.png
```

O shader Metal é compilado quando o app abre (`makeLibrary(source:)`), por isso o projeto compila só com as Command Line Tools.

## Limitações

- **Timer local**: o timer roda no Mac. Enquanto ele está ativo, o Mac não dorme por inatividade, mas se a tampa for fechada o ar só desliga quando o Mac acordar. O app oficial agenda pela nuvem (`/energy-service/api/device/saveScheduler`), mas o formato desse payload ainda não foi mapeado.
- **Testado** com um split Hisense numa conta do Brasil. Outros modelos podem expor propriedades diferentes. As funções extras só aparecem quando o aparelho as informa.
- **Não-oficial**: a nuvem pode mudar a qualquer momento e quebrar o app.

## Créditos

- [oyvindwe/connectlife](https://github.com/oyvindwe/connectlife), cliente Python open source da nuvem ConnectLife. As credenciais de cliente e o algoritmo de assinatura deste projeto seguem a implementação dele.
- [morluto/rea](https://github.com/morluto/rea), usado para verificar o protocolo no app oficial.

## Aviso

Projeto pessoal, **não afiliado** à Hisense nem à ConnectLife. Use por sua conta e risco. A senha da ConnectLife fica só no Keychain do seu Mac e é enviada apenas aos servidores de login da própria ConnectLife (Gigya).

## Licença

[GPL-3.0](LICENSE)
