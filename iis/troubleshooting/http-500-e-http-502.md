# IIS — HTTP 500 e HTTP 502

> O número depois do ponto é a informação mais valiosa da mensagem, e a que quase sempre é
> ignorada. `500.19` e `500.30` são problemas completamente diferentes.

| | |
|---|---|
| **Sintoma** | `HTTP Error 500.x` ou `HTTP Error 502.x` |
| **Compatibilidade** | IIS 8.5+ · .NET Framework e ASP.NET Core |

---

## Tabela de subcódigos

| Código | Significado | Onde olhar |
|---|---|---|
| **500.19** | Erro de configuração: `web.config` inválido, módulo ausente ou sem permissão de leitura | O próprio `web.config` e as permissões da pasta |
| **500.21** | Handler do `web.config` não registrado no IIS | Registro do ASP.NET / recursos do IIS |
| **500.30** | ASP.NET Core: falha ao **iniciar** a aplicação | `stdout` log e log Aplicativo |
| **500.31** | ASP.NET Core: falha ao carregar o framework (versão ausente) | `dotnet --list-runtimes` |
| **500.32** | ASP.NET Core: incompatibilidade de arquitetura (x86 x x64) | Configuração do pool |
| **500.33** | ASP.NET Core: não é uma aplicação web (falta `Microsoft.AspNetCore.App`) | Publicação |
| **500.34** | Modo `in-process` com múltiplas aplicações no mesmo pool | Um pool por aplicação |
| **500.35** | Idem, para várias aplicações in-process | Um pool por aplicação |
| **500.36** | Handler *out-of-process* usado em contexto incorreto | `hostingModel` no `web.config` |
| **502.5** | ASP.NET Core: o processo falhou ao iniciar ou morreu logo depois | `stdout` log |
| **502.3** | Erro de gateway: timeout ou falha na comunicação com o processo | Timeout do ANCM, ou aplicação travada |

---

## Passo 1 — Ver o erro de verdade

O IIS esconde os detalhes quando o navegador é remoto. Para ver a mensagem completa
**durante o diagnóstico**:

```xml
<!-- web.config -- APENAS EM DIAGNOSTICO -->
<system.webServer>
  <httpErrors errorMode="Detailed" />
</system.webServer>
```

Em aplicações .NET Framework:

```xml
<system.web>
  <customErrors mode="Off" />
</system.web>
```

> **Reverta depois.** Erro detalhado em produção expõe caminhos de arquivo, stack trace,
> nomes de servidor e, às vezes, trechos de connection string. É informação valiosa para um
> atacante.

Alternativa sem alterar configuração: acessar `http://localhost/...` **no próprio
servidor**, onde o IIS mostra o detalhe por padrão.

---

## HTTP 500.19 — configuração

O subcódigo mais comum, e o que tem mais causas distintas:

| Causa | Como confirmar | Correção |
|---|---|---|
| XML mal formado no `web.config` | Abrir o arquivo; a mensagem indica a linha | Corrigir o XML |
| Módulo referenciado não instalado (ex.: URL Rewrite) | A mensagem cita o módulo | Instalar o módulo no servidor |
| ASP.NET Core Module ausente | `500.19` logo após publicar em servidor novo | Instalar o **.NET Hosting Bundle** |
| Sem permissão de leitura no `web.config` | Identidade do pool sem acesso à pasta | Conceder leitura à identidade |
| Seção bloqueada no nível do servidor | A mensagem indica a seção | Desbloquear com `appcmd unlock config` |

```powershell
# Validar a configuracao do site
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list config "MeuSite"

# Confirmar que o ASP.NET Core Module esta registrado
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list modules | Select-String "AspNetCore"
```

> Servidor novo + aplicação ASP.NET Core + `500.19` é quase sempre **Hosting Bundle não
> instalado**. Depois de instalar, reinicie o IIS (`iisreset`).

---

## HTTP 500.30 e 502.5 — a aplicação não sobe

O processo falhou ao iniciar. A causa está na saída do processo, não no IIS.

### Habilitar o log de saída

```xml
<aspNetCore processPath="dotnet"
            arguments=".\MinhaApi.dll"
            stdoutLogEnabled="true"
            stdoutLogFile=".\logs\stdout"
            hostingModel="inprocess">
  <environmentVariables>
    <environmentVariable name="ASPNETCORE_ENVIRONMENT" value="Production" />
  </environmentVariables>
</aspNetCore>
```

A pasta `logs` precisa **existir** e ser gravável pela identidade do pool. Se não existir,
nenhum arquivo é criado — e a ausência de log é confundida com ausência de erro.

### Executar fora do IIS — o atalho mais rápido

```powershell
cd C:\inetpub\wwwroot\MinhaApi
dotnet .\MinhaApi.dll
```

Se falhar aqui, o erro aparece direto no console, com stack trace completo. Isola o
problema da aplicação do problema de hospedagem em segundos.

### Causas mais comuns

| Causa | Sintoma |
|---|---|
| Runtime .NET ausente ou de versão errada | `500.31`; confirme com `dotnet --list-runtimes` |
| Connection string inválida | Exceção na inicialização, visível no `stdout` |
| Cofre de segredos inacessível | Timeout ou falha de autenticação no startup |
| Certificado sem permissão na chave privada | Exceção de criptografia |
| Porta em uso (modo out-of-process) | `502.5` |
| `appsettings.Production.json` ausente | Configuração obrigatória não encontrada |
| Arquitetura incompatível | `500.32` — pool em 32 bits com publicação x64 |

```powershell
# Runtimes instalados
dotnet --list-runtimes

# O pool esta em 32 bits?
Get-ItemProperty "IIS:\AppPools\MeuAppPool" -Name enable32BitAppOnWin64
```

---

## HTTP 500 genérico em .NET Framework

Sem subcódigo, o 500 é exceção não tratada dentro da aplicação. Onde procurar:

1. **Log da aplicação** — se houver.
2. **Visualizador de Eventos**, log Aplicativo, origem `ASP.NET`.
3. **Failed Request Tracing** (a ferramenta mais subutilizada do IIS):

```powershell
# Habilitar rastreamento para o codigo 500 em um site
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" set config "MeuSite" `
    -section:system.webServer/tracing/traceFailedRequests `
    /+"[path='*',customActionExe='']" /commit:apphost
```

A configuração pelo Gerenciador do IIS é mais simples: **Failed Request Tracing Rules** →
**Add**, escolher o status 500, e habilitar o rastreamento no site. Os arquivos ficam em
`%SystemDrive%\inetpub\logs\FailedReqLogFiles` e abrem no navegador com um XSL que mostra
cada módulo e o tempo gasto — incluindo exatamente onde a requisição falhou.

> FREB tem custo. Habilite com filtro (um status, uma URL), diagnostique e **desligue**.

---

## Logs do IIS

```powershell
# Local padrao
Get-ChildItem "$env:SystemDrive\inetpub\logs\LogFiles" -Recurse -Filter *.log |
    Sort-Object LastWriteTime -Descending | Select-Object -First 5
```

O campo `sc-status` traz o status HTTP; `sc-substatus`, o subcódigo; `sc-win32-status`, o
código de erro do Windows; e `time-taken`, a duração em milissegundos.

Para traduzir um `sc-win32-status`:

```powershell
net helpmsg <CODIGO>
```

---

## Aplicação sobe e cai depois — memory leak

Quando o 500/502 aparece depois de horas de operação normal, o padrão é outro: consumo de
memória crescente até a reciclagem ou a queda.

```powershell
# Acompanhar o consumo dos processos de trabalho
Get-Process w3wp | Select-Object Id, WorkingSet64, PrivateMemorySize64, StartTime
```

Suspeitos mais frequentes:

| Suspeito | Onde ler |
|---|---|
| `HttpClient` criado em laço | [`../../dotnet/httpclient/httpclient-uso-correto.md`](../../dotnet/httpclient/httpclient-uso-correto.md) |
| Conexões de banco não descartadas | [`../../acesso-a-dados/ado-net/connection-pool-esgotado.md`](../../acesso-a-dados/ado-net/connection-pool-esgotado.md) |
| `DbContext` singleton acumulando entidades | [`../../acesso-a-dados/entity-framework-core/ef-core-performance.md`](../../acesso-a-dados/entity-framework-core/ef-core-performance.md) |
| Cache estático sem limite nem expiração | Revisar a política de cache |
| Eventos assinados e nunca liberados | Revisar `+=` sem `-=` |

Para análise a fundo, capture um dump do processo e analise as raízes de retenção. Sem
dump, a investigação vira adivinhação.

---

## Checklist de diagnóstico

- [ ] Anotei o **subcódigo** completo (500.19, 500.30, 502.5...).
- [ ] Vi o erro detalhado (localmente ou com `errorMode="Detailed"` temporário).
- [ ] Conferi o Visualizador de Eventos, logs Aplicativo **e** Sistema.
- [ ] Em ASP.NET Core: habilitei o `stdout` log, ou executei `dotnet MinhaApi.dll` à mão.
- [ ] Conferi `dotnet --list-runtimes` no servidor.
- [ ] Conferi as permissões da identidade do pool sobre a pasta da aplicação.
- [ ] **Reverti** `errorMode` e `stdoutLogEnabled` ao terminar.

## Referências

- [Solucionar problemas do ASP.NET Core no IIS](https://learn.microsoft.com/pt-br/aspnet/core/test/troubleshoot-azure-iis)
- [Módulo ASP.NET Core (ANCM)](https://learn.microsoft.com/pt-br/aspnet/core/host-and-deploy/aspnet-core-module)
- [Failed Request Tracing](https://learn.microsoft.com/pt-br/iis/troubleshoot/using-failed-request-tracing/troubleshooting-failed-requests-using-tracing-in-iis)

---

**Criado por Fábio Cerqueira**
