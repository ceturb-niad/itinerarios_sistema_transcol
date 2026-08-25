#!/usr/bin/env bash
# Converte o gpkg mestre num único KML com uma Folder por categoria.
#
# O driver KML do OGR mapeia 1 layer -> 1 Folder, mas o gpkg de origem
# tem uma única tabela ("itinerarios") — a conversão direta sai sempre
# achatada. Em vez de várias chamadas de ogr2ogr encadeadas com
# -update -append (arriscado: -dsco NameField só é garantidamente
# aplicada na criação do dataset, não em reaberturas subsequentes — a
# primeira categoria sairia nomeada e as demais voltariam a ficar sem
# nome), este script gera um VRT com uma OGRVRTLayer por categoria —
# cada uma com seu próprio SrcSQL filtrando por categoria — e converte
# tudo numa única chamada de ogr2ogr: uma única criação de dataset, um
# único NameField válido para todas as folders.
#
# Categorias descobertas em runtime via DISTINCT sobre os dados, não
# hardcoded — evita mais um lugar pra sincronizar manualmente com
# CATEGORIAS_TODAS (já duplicado entre os scripts do toolbox QGIS por
# decisão de arquitetura anterior; aqui a robustez de derivar da fonte
# pesa mais que consistência com aquele padrão).
#
# Uso: converter_kml_por_categoria.sh <caminho_gpkg> <caminho_kml_saida>
set -euo pipefail

GPKG="$(readlink -f "$1")"
OUT_KML="$2"

if [ ! -f "$GPKG" ]; then
  echo "gpkg não encontrado: $GPKG" >&2
  exit 1
fi

# gpkg tem uma única tabela de itinerários — extrai o nome real da layer
# em vez de hardcodar, já que depende de como o sink do QGIS gravou o
# arquivo (pode não ser literalmente "itinerarios")
LAYER=$(ogrinfo -q "$GPKG" | sed -n 's/^1: \([^ ]*\).*/\1/p')
if [ -z "$LAYER" ]; then
  echo "Não foi possível identificar a layer do gpkg '$GPKG' (esperada exatamente 1 layer)." >&2
  exit 1
fi
echo "Layer identificada: $LAYER"

mapfile -t CATEGORIAS < <(
  ogr2ogr -f CSV /vsistdout/ "$GPKG" \
    -sql "SELECT DISTINCT categoria FROM \"$LAYER\" WHERE categoria IS NOT NULL AND categoria != '' ORDER BY categoria" \
    | tail -n +2
)

if [ ${#CATEGORIAS[@]} -eq 0 ]; then
  echo "Nenhuma categoria encontrada em '$LAYER' — abortando (esperado ao menos 1)." >&2
  exit 1
fi
echo "Categorias encontradas (${#CATEGORIAS[@]}): ${CATEGORIAS[*]}"

VRT=$(mktemp --suffix=.vrt)
{
  echo '<OGRVRTDataSource>'
  for CAT in "${CATEGORIAS[@]}"; do
    echo "  <OGRVRTLayer name=\"${CAT}\">"
    echo "    <SrcDataSource>${GPKG}</SrcDataSource>"
    echo "    <SrcSQL>SELECT * FROM \"${LAYER}\" WHERE categoria='${CAT}'</SrcSQL>"
    echo '  </OGRVRTLayer>'
  done
  echo '</OGRVRTDataSource>'
} > "$VRT"

rm -f "$OUT_KML"
ogr2ogr -f KML -t_srs EPSG:4326 -dsco NameField=itinerario "$OUT_KML" "$VRT"
rm -f "$VRT"

echo "KML gerado com ${#CATEGORIAS[@]} pasta(s) por categoria: $OUT_KML"
