# Pipeline de CI para .NET no GitHub Actions

> Workflow de build, teste e publicação para .NET, com o que costuma quebrar em cada etapa e como
> tratar segredos sem vazá-los no log.

| | |
|---|---|
| **Compatibilidade** | .NET SDK 6.0+ nos runners hospedados. Projetos de .NET Framework exigem runner `windows-latest` e MSBuild — ver seção específica. |
| **Impacto** | Nenhum sobre produção enquanto o workflow só fizer build e teste. |
| **Custo** | Minutos de Actions. Runner Linux consome 1×; Windows consome 2×; macOS, 10×. Use `ubuntu-latest` sempre que o projeto permitir. |

---

## Problema

Pipeline de CI para .NET é fácil de fazer funcionar e fácil de fazer errado de um jeito que só
aparece meses depois:

- o build passa no CI e quebra na máquina de quem faz o deploy, porque o CI restaurava de um cache
  desatualizado;
- o teste "passa" porque nenhum teste rodou — o filtro não casou com nada e o `dotnet test`
  retornou zero;
- o token de deploy aparece no log porque alguém fez `echo` da variável para depurar;
- a pipeline leva 14 minutos porque restaura os pacotes NuGet do zero a cada execução.

---

## Solução — workflow de build e teste

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

# Cancela execucoes antigas do mesmo branch quando um push novo chega.
concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

# Menor privilegio: por padrao o GITHUB_TOKEN so le.
permissions:
  contents: read

jobs:
  build-e-teste:
    runs-on: ubuntu-latest
    timeout-minutes: 15

    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Instalar .NET SDK
        uses: actions/setup-dotnet@v6
        with:
          # Prefira global.json como fonte unica da versao do SDK.
          global-json-file: global.json
          cache: true
          cache-dependency-path: '**/packages.lock.json'

      - name: Restore
        run: dotnet restore --locked-mode

      - name: Build
        run: dotnet build --configuration Release --no-restore

      - name: Testes
        run: >
          dotnet test
          --configuration Release
          --no-build
          --logger "trx;LogFileName=resultado.trx"
          --results-directory ./artefatos-teste
          --collect:"XPlat Code Coverage"

      - name: Publicar resultado dos testes
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: resultado-testes
          path: ./artefatos-teste
          retention-days: 7
```

### O que cada decisão está resolvendo

**`concurrency` com `cancel-in-progress`** — sem isso, cinco pushes seguidos em um Pull Request
disparam cinco pipelines completas. Só a última interessa.

**`permissions: contents: read`** — o `GITHUB_TOKEN` injetado no workflow tem escopo configurável.
O padrão de organizações antigas é permissivo. Declarar o mínimo no topo e ampliar apenas no job
que precisa é a aplicação de menor privilégio ao CI.

**`global-json-file`** — fixar a versão do SDK em um `global.json` versionado evita que uma
atualização silenciosa do runner mude o compilador debaixo do projeto:

```json
{
  "sdk": {
    "version": "8.0.400",
    "rollForward": "latestFeature"
  }
}
```

**`cache: true` no `setup-dotnet`** — a própria action cuida do cache do NuGet. Ela exige um
arquivo de lock (`packages.lock.json`) para calcular a chave. Para gerá-los:

```bash
dotnet restore --use-lock-file
```

**`--locked-mode`** — falha o restore se o `packages.lock.json` não bater com os `PackageReference`.
É o que garante que o CI compila exatamente as versões que você revisou, e não a versão nova de
uma dependência transitiva publicada ontem.

**`--no-restore` e `--no-build`** — além de economizar tempo, garantem que o passo de teste roda
sobre o binário que o passo de build produziu, e não sobre uma recompilação implícita com outras
opções.

**`if: always()` no upload** — sem isso, o resultado dos testes só é publicado quando os testes
passam, que é justamente quando você não precisa dele.

---

## Armadilha: teste que passa sem ter rodado

`dotnet test` retorna 0 quando o filtro não seleciona nenhum teste. A pipeline fica verde e
ninguém percebe que a suíte inteira parou de rodar meses atrás.

O VSTest oferece uma trava para isso — `RunConfiguration.TreatNoTestsAsError`, cujo padrão é
`false`:

```bash
dotnet test --configuration Release --no-build -- \
  RunConfiguration.TreatNoTestsAsError=true
```

O mesmo pode ficar fixo em um `.runsettings` versionado:

```xml
<RunSettings>
  <RunConfiguration>
    <TreatNoTestsAsError>true</TreatNoTestsAsError>
  </RunConfiguration>
</RunSettings>
```

Alternativa independente disso — verificar o `.trx`:

```yaml
      - name: Garantir que testes rodaram
        shell: bash
        run: |
          total=$(grep -o 'total="[0-9]*"' ./artefatos-teste/resultado.trx | head -1 | grep -o '[0-9]*')
          echo "Testes executados: ${total:-0}"
          if [ "${total:-0}" -lt 1 ]; then
            echo "::error::Nenhum teste foi executado."
            exit 1
          fi
```

---

## Armadilha: formatação e analisadores

Discussão de estilo em Pull Request é desperdício de revisão humana. Deixe a máquina resolver:

```yaml
      - name: Verificar formatacao
        run: dotnet format --verify-no-changes --verbosity diagnostic
```

`dotnet format` está embutido no SDK desde a versão 6. Ele falha o build se houver arquivo fora do
padrão definido no `.editorconfig` — sem alterar nada.

Para tratar warnings de compilação como erro **apenas no CI**, sem atrapalhar o desenvolvimento
local:

```bash
dotnet build --configuration Release -warnaserror
```

---

## Segredos no GitHub Actions

### Onde ficam

**Settings → Secrets and variables → Actions.** Existem três escopos: organização, repositório e
*environment*. Segredo de produção deve ficar em **environment**, porque environment aceita regra
de aprovação manual e restrição de branch.

### Como usar

```yaml
      - name: Publicar pacote
        env:
          NUGET_API_KEY: ${{ secrets.NUGET_API_KEY }}
        run: dotnet nuget push ./pacotes/*.nupkg --api-key "$NUGET_API_KEY" --source https://api.nuget.org/v3/index.json
```

### Regras que não se negociam

1. **Nunca faça `echo` de um segredo.** O GitHub mascara valores conhecidos no log, mas o
   mascaramento é textual: se você transformar o valor (base64, JSON, quebra de linha), o
   mascaramento não pega mais.
2. **Passe por `env`, não por interpolação direta na linha de comando.** `run: comando ${{ secrets.X }}`
   coloca o valor no comando montado, o que o expõe a interpretação do shell e ao rastro em
   ferramentas de diagnóstico.
3. **Pull Request de fork não recebe segredos.** Isso é proposital. Se o seu workflow de PR precisa
   de segredo, provavelmente ele está fazendo algo que deveria estar no workflow de `push`.
4. **`pull_request_target` executa com segredos e com o código do branch base** — é o padrão
   correto para automação de rótulo e comentário, e um risco sério se você fizer checkout do código
   do PR dentro dele. Nesse caso, o código não confiável do contribuidor roda com acesso aos
   segredos do repositório.
5. **Não use segredo para o que uma federação resolve.** Publicação em nuvem via OIDC
   (`id-token: write`) dispensa guardar credencial de longa duração no repositório.

---

## Publicação do artefato

```yaml
      - name: Publish
        run: >
          dotnet publish ./src/Api/Api.csproj
          --configuration Release
          --no-build
          --output ./publicado

      - name: Upload do artefato
        uses: actions/upload-artifact@v4
        with:
          name: api-${{ github.sha }}
          path: ./publicado
          retention-days: 30
```

Publicar o artefato **uma vez** e promovê-lo entre ambientes é a diferença entre "testamos o que
foi para produção" e "testamos algo parecido com o que foi para produção". Rebuild por ambiente
reintroduz variabilidade exatamente onde ela custa mais caro.

---

## Projeto .NET Framework (4.x)

Projeto legado com `packages.config` e `.csproj` no formato antigo **não compila com
`dotnet build`**. É preciso MSBuild em runner Windows:

```yaml
jobs:
  build-framework:
    runs-on: windows-latest
    timeout-minutes: 20

    steps:
      - uses: actions/checkout@v6

      - name: Adicionar MSBuild ao PATH
        uses: microsoft/setup-msbuild@v2

      - name: NuGet restore
        run: nuget restore ./MinhaSolucao.sln

      - name: Build
        run: msbuild ./MinhaSolucao.sln /p:Configuration=Release /p:Platform="Any CPU" /m

      - name: Testes
        run: |
          $vstest = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Workload.ManagedDesktop -find "**\vstest.console.exe" | Select-Object -First 1
          & $vstest .\tests\Testes\bin\Release\Testes.dll /Logger:trx
        shell: pwsh
```

Notas para esse cenário:

- Runner Windows consome o dobro de minutos. Vale isolar o job de Framework para que ele só rode
  quando os arquivos correspondentes mudarem (`on.push.paths`).
- Se o projeto for Web (`.csproj` com `WebApplication`), o pacote de publicação sai com
  `/p:DeployOnBuild=true /p:WebPublishMethod=Package`.
- `nuget restore` e `msbuild` não compartilham cache com `dotnet restore`. O cache do NuGet fica em
  `~\AppData\Local\NuGet\v3-cache` — use `actions/cache` explicitamente se o restore for lento.

---

## Fixar versões das actions

O exemplo acima usa `@v6`, que é uma tag móvel: o mantenedor pode mover `v6` para um commit novo a
qualquer momento. Para repositório que lida com segredo relevante, fixe o commit:

```yaml
      - uses: actions/checkout@<SHA-COMPLETO-DE-40-CARACTERES> # v6.0.3
```

O SHA você copia da página de releases da action, ou com
`git ls-remote https://github.com/actions/checkout refs/tags/v6.0.3`. Sempre o SHA completo de 40
caracteres — SHA abreviado é ambíguo e o GitHub o rejeita nesse contexto.

Essa é a recomendação de hardening do próprio GitHub. O custo é ter que atualizar os SHAs — o
Dependabot faz isso automaticamente com um `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
  - package-ecosystem: "nuget"
    directory: "/"
    schedule:
      interval: "weekly"
```

---

## Quando NÃO utilizar

- **Não coloque deployment de produção no mesmo job do build.** Separe em job com `environment:`
  e aprovação manual. Job único significa que qualquer merge vai para produção.
- **Não use GitHub Actions para acessar SQL Server em rede interna** sem antes resolver
  conectividade. Runner hospedado não enxerga a rede corporativa. Isso pede self-hosted runner —
  que traz seu próprio conjunto de considerações de segurança, porque o código do workflow executa
  dentro do seu perímetro.
- **Não rode migração de banco no CI de Pull Request.** Migração pertence ao pipeline de
  deployment, com o cuidado descrito em
  [estrategias-de-deployment-e-rollback.md](../deployment/estrategias-de-deployment-e-rollback.md).

---

## Checklist

- [ ] `permissions` declarado no topo com o mínimo necessário.
- [ ] `concurrency` com `cancel-in-progress` configurado.
- [ ] `timeout-minutes` definido em todo job (evita job travado consumindo minutos).
- [ ] Versão do SDK fixada em `global.json`.
- [ ] `packages.lock.json` versionado e `--locked-mode` no restore.
- [ ] Trava contra "zero testes executados".
- [ ] Resultado de teste publicado com `if: always()`.
- [ ] Nenhum segredo interpolado direto em `run:` — sempre via `env:`.
- [ ] Segredo de produção em *environment* com aprovação, não em segredo de repositório.
- [ ] Secret scanning e push protection ativos no repositório.
- [ ] Artefato publicado uma vez e promovido entre ambientes.

---

## Referências

- [GitHub Docs — Building and testing .NET](https://docs.github.com/en/actions/tutorials/build-and-test-code/net)
- [GitHub Docs — Using secrets in GitHub Actions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)
- [GitHub Docs — Security hardening for GitHub Actions](https://docs.github.com/en/actions/reference/security/secure-use)
- [`actions/setup-dotnet`](https://github.com/actions/setup-dotnet)
- [Microsoft Learn — `dotnet test`](https://learn.microsoft.com/dotnet/core/tools/dotnet-test)
- [Microsoft Learn — Configurar testes com `.runsettings`](https://learn.microsoft.com/visualstudio/test/configure-unit-tests-by-using-a-dot-runsettings-file)
- [Microsoft Learn — `global.json` overview](https://learn.microsoft.com/dotnet/core/tools/global-json)

---

**Criado por Fábio Cerqueira**
