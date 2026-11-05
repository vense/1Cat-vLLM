#!/bin/bash
# 1Cat-vLLM main (b2b6b3bb91, 2026-11-04) + ppc64le-v100-main fixes for ppc64le + V100, built stage by stage on gpu3.
#   /mnt/nas0/models/cont/bin/rrun build.sh                 # all stages in order, then push the final image
#   /mnt/nas0/models/cont/bin/rrun build.sh base            # one stage only (and its ancestors from cache)
#   /mnt/nas0/models/cont/bin/rrun build.sh --from build    # resume: this stage and everything after it
#   /mnt/nas0/models/cont/bin/rrun build.sh --list          # show the stages
# Every stage is tagged 1cat-vllm-stage:<stage>-<ver> so it can be inspected (docker run -it --rm <tag> bash)
# and so later stages pick it up from the BuildKit cache without rebuilding. With PUSH_STAGES=1 the stage
# images are also pushed to the registry, which keeps the cache alive across `docker system prune`.
#
# Context is ./vllm/ (git checkout). The Dockerfile is fed on stdin so BuildKit does not scan this directory.
# Do NOT pass MAX_JOBS (it would invalidate the torch-builder cache reused from vllm/0.19.1-torch2.10.0);
# max_jobs (lowercase) only drives the vLLM extension build.
#
# Stages (Dockerfile.ppc64le_cuda):
#   llvm-triton      LLVM 15 + Triton 3.6 wheel                       (hours, cached from vllm/0.19.1)
#   torch-builder    torch 2.10 / torchvision / torchaudio wheels      (hours, cached from vllm/0.19.1)
#   base             CUDA 12.4 devel + python 3.12 + torch + triton    (minutes)
#   xgrammar-builder xgrammar 0.2.8 wheel                              (~20 min)
#   build            vLLM wheel: CUDA extensions + flash-attention-v100 + flash_qla sm70 (1-2 h; ccache helps)
#   vllm-base        runtime image: wheels installed, torch patch, import check
#   vllm-openai      final image (ENTRYPOINT vllm serve)
set -euo pipefail
VER=1.5.2
TAG=repo.dev.ktl.int:5000/1cat-vllm:${VER}-ppc64le-cuda-test
STAGES=(llvm-triton torch-builder base xgrammar-builder build vllm-base vllm-openai)
PUSH_STAGES=${PUSH_STAGES:-0}

usage() { sed -n '2,10p' "$0"; exit "${1:-0}"; }
case "${1:-all}" in
  --list) printf '%s\n' "${STAGES[@]}"; exit 0 ;;
  -h|--help) usage ;;
  --from) [[ -n ${2:-} ]] || usage 2; start=$2; todo=(); hit=0
          for s in "${STAGES[@]}"; do [[ $s == "$start" ]] && hit=1; [[ $hit == 1 ]] && todo+=("$s"); done
          [[ $hit == 1 ]] || { echo "unknown stage: $start"; usage 2; } ;;
  all) todo=("${STAGES[@]}") ;;
  *) todo=("$1"); [[ " ${STAGES[*]} " == *" $1 "* ]] || { echo "unknown stage: $1"; usage 2; } ;;
esac

cd ./vllm/
echo "== source: $(git describe --tags --always --dirty) ($(git rev-parse --abbrev-ref HEAD))"
echo "== stages: ${todo[*]}"
for stage in "${todo[@]}"; do
  if [[ $stage == vllm-openai ]]; then out=$TAG; else out=1cat-vllm-stage:${stage}-${VER}; fi
  t0=$(date +%s)
  echo "==== [$(date '+%F %T')] stage $stage -> $out"
  DOCKER_BUILDKIT=1 docker build . --progress=plain \
      --target "$stage" --tag "$out" \
      --build-arg BUILDKIT_INLINE_CACHE=1 \
      --build-arg max_jobs=96 --build-arg nvcc_threads=4 \
      --file - < ../Dockerfile.ppc64le_cuda
  echo "==== [$(date '+%F %T')] stage $stage done in $(( ($(date +%s) - t0) / 60 )) min"
  if [[ $stage == vllm-openai ]]; then
    docker push "$TAG"
  elif [[ $PUSH_STAGES == 1 ]]; then
    docker tag "$out" "repo.dev.ktl.int:5000/$out" && docker push "repo.dev.ktl.int:5000/$out"
  fi
done
echo "==== all done: ${todo[*]}"
