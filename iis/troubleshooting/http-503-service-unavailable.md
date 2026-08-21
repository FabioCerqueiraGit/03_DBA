# IIS — HTTP 503 Service Unavailable

> HTTP 503 no IIS quase sempre significa uma coisa: **o Application Pool está parado**. E
> ele não parou sozinho — o IIS o parou depois de o processo falhar repetidamente.

| | |
|---|---|
| **Sintoma** | `HTTP Error 503. The service is unavailable.` |
| **Compatibilidade** | IIS 8.5+ · aplicações .NET Framework e ASP.NET Core |
| **Urgência** | Aplicação fora do ar |

---

## Passo 1 — O Application Pool está rodando?

```powershell
# Estado de todos os pools
Import-Module WebAdministration
Get-ChildItem IIS:\AppPools | Select-Object Name, State, ManagedRuntimeVersion

# Ou com appcmd
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list apppool
```

Saída típica do problema:

```text
APPPOOL "MeuAppPool" (MgdVersion:v4.0,MgdMode:Integrated,state:Stopped)
```

**`state:Stopped` é a confirmação.** Reiniciar resolve o minuto seguinte — e se você parar
aqui, ele para de novo.

```powershell
Start-WebAppPool -Name "MeuAppPool"
```

**Antes de reiniciar, vá ao Passo 2.** O motivo da parada está registrado, e some do foco
depois que tudo volta.

---

## Passo 2 — Por que ele parou? (Rapid-Fail Protection)

O IIS tem uma proteção: se o processo de trabalho falhar N vezes em um intervalo, o pool
é **desligado** para não entrar em ciclo infinito de reinicialização. O padrão costuma ser
**5 falhas em 5 minutos**.

```powershell
Get-ItemProperty "IIS:\AppPools\MeuAppPool" -Name failure |
    Select-Object rapidFailProtection,
                  rapidFailProtectionInterval,
                  rapidFailProtectionMaxCrashes
```

O registro fica no **Visualizador de Eventos**, log **Sistema**, origem **WAS**:

```powershell
Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WAS' } |
    Select-Object -First 20 TimeCreated, Id, Message | Format-List
```

| Evento WAS | Significado |
|---|---|
| **5002** | O pool foi desligado por Rapid-Fail Protection — este é o evento-chave |
| **5009** | O processo de trabalho terminou de forma inesperada |
| **5011** | O processo não conseguiu se comunicar com o WAS |
| **5057** | Falha ao iniciar — frequentemente identidade ou permissão |
| **5021** | **Credencial da identidade do pool inválida** (senha alterada ou expirada) |
| **5117** | O pool foi desabilitado por falha no processo |

Em paralelo, o log **Aplicativo** costuma trazer a exceção que derrubou o processo:

```powershell
Get-WinEvent -FilterHashtable @{
    LogName   = 'Application'
    Level     = 1,2               # Critico e Erro
    StartTime = (Get-Date).AddHours(-2)
} | Select-Object -First 20 TimeCreated, ProviderName, Id, Message | Format-List
```

---

## As cinco causas, em ordem de frequência

### 1. Senha da identidade do pool expirou

O caso mais comum em ambiente corporativo com política de troca periódica de senha. O
sintoma é característico: **funcionava até ontem, ninguém fez deploy**.

Evento **5021** confirma.

```powershell
# Conferir a identidade configurada
Get-ItemProperty "IIS:\AppPools\MeuAppPool" -Name processModel |
    Select-Object identityType, userName
```

**Correção definitiva:** usar uma **Group Managed Service Account (gMSA)** ou
`ApplicationPoolIdentity`. A gMSA tem a senha gerenciada pelo domínio e rotacionada
automaticamente — elimina essa classe inteira de incidente.

### 2. Exceção não tratada derrubando o processo

Exceção em thread de background, em `async void`, ou em um `BackgroundService` sem
tratamento derruba o processo inteiro. Cinco quedas em cinco minutos e o pool para.

O log **Aplicativo** traz a exceção. Veja também
[`../../dotnet/async-await/armadilhas-async-await.md`](../../dotnet/async-await/armadilhas-async-await.md).

### 3. Falha na inicialização

Connection string errada, arquivo de configuração inválido, dependência ausente, cofre de
segredos inacessível. A aplicação nem chega a subir.

Em ASP.NET Core, habilite temporariamente o log de saída padrão:

```xml
<!-- web.config -->
<aspNetCore processPath="dotnet"
            arguments=".\MinhaApi.dll"
            stdoutLogEnabled="true"
            stdoutLogFile=".\logs\stdout"
            hostingModel="inprocess" />
```

A pasta `logs` precisa **existir** e ser gravável pela identidade do pool. Desligue depois
de diagnosticar: o arquivo cresce sem rotação.

### 4. Limite de memória ou reciclagem agressiva

```powershell
Get-ItemProperty "IIS:\AppPools\MeuAppPool" -Name recycling.periodicRestart |
    Select-Object memory, privateMemory, requests, time
```

Se `privateMemory` estiver definido com um valor baixo, o pool recicla o tempo todo. Sob
carga, isso vira indisponibilidade intermitente.

### 5. Fila de requisições cheia

Quando as requisições chegam mais rápido do que a aplicação processa, a fila do HTTP.sys
enche e o IIS responde 503 **sem nem chamar** a aplicação.

```powershell
Get-ItemProperty "IIS:\AppPools\MeuAppPool" -Name queueLength
```

Aumentar a fila **não resolve** — só aumenta o tempo de espera antes do erro. A causa é
lentidão no processamento. Investigue:

- threads bloqueadas por `.Result`/`.Wait()` — [`../../dotnet/async-await/armadilhas-async-await.md`](../../dotnet/async-await/armadilhas-async-await.md);
- pool de conexão esgotado — [`../../acesso-a-dados/ado-net/connection-pool-esgotado.md`](../../acesso-a-dados/ado-net/connection-pool-esgotado.md);
- queries lentas — [`../../sql-server/performance/`](../../sql-server/performance/).

---

## Ver o que os processos estão fazendo agora

```powershell
# Processos de trabalho ativos e a que pool pertencem
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list wp

# Requisicoes em execucao ha mais de 5 segundos -- mostra ONDE a aplicacao trava
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list requests /elapsed:5000
```

O segundo comando é subestimado: ele lista as requisições presas com URL, verbo, tempo
decorrido e o **módulo/estágio** em que estão — o que aponta diretamente se o gargalo está
na aplicação, no banco ou em uma chamada externa.

---

## Árvore de decisão

```text
HTTP 503
│
├─ Application Pool parado?
│   ├─ Sim, evento WAS 5021        -> senha da identidade expirou
│   ├─ Sim, evento WAS 5002        -> Rapid-Fail: veja o log Aplicativo
│   └─ Sim, sem evento claro       -> parada manual? verifique o histórico de mudanças
│
├─ Pool rodando, mas 503 mesmo assim
│   ├─ appcmd list requests mostra fila -> lentidão no processamento
│   └─ Nada na fila                     -> verifique o site e os bindings
│
└─ O pool para de novo logo apos iniciar
    └─ Falha na inicialização -> stdout log (ASP.NET Core) ou log Aplicativo
```

---

## Mitigação versus correção

| | Mitigação | Correção |
|---|---|---|
| **Ação** | `Start-WebAppPool` | Corrigir a exceção, a senha ou a lentidão |
| **Dura** | Até falhar cinco vezes de novo | Definitivo |
| **Antes de mitigar** | Copie os eventos WAS e as exceções do log Aplicativo | — |

Como em qualquer incidente, **salve a evidência antes**. Depois que o pool reinicia, a
pressão para investigar desaparece — e o problema volta na semana seguinte.

---

## Prevenção

- [ ] Identidade do pool com **gMSA** ou `ApplicationPoolIdentity` — sem senha para expirar.
- [ ] Monitoramento do estado dos Application Pools, com alerta.
- [ ] Alerta nos eventos WAS 5002, 5009, 5021 e 5117.
- [ ] Health check no balanceador, apontando para um endpoint real da aplicação.
- [ ] Log de exceção não tratada centralizado.
- [ ] Reciclagem por horário fixo em vez de por memória, quando possível.
- [ ] `stdoutLogEnabled` **desligado** em produção (ligue só para diagnosticar).

## Referências

- [Solucionar problemas do ASP.NET Core no IIS](https://learn.microsoft.com/pt-br/aspnet/core/test/troubleshoot-azure-iis)
- [Módulo ASP.NET Core (ANCM)](https://learn.microsoft.com/pt-br/aspnet/core/host-and-deploy/aspnet-core-module)
- [Identidades de Application Pool](https://learn.microsoft.com/pt-br/iis/manage/configuring-security/application-pool-identities)

---

**Criado por Fábio Cerqueira**
