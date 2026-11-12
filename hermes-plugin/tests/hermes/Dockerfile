# Hermes itself, for tests/test_reviews_hermes.py: its source at one commit, and its dependencies as
# its own uv.lock pins them. Built and run by ../../test-with-hermes.sh, which also names the commit
# (HERMES_REF); the plugin is mounted at /plugin when the container runs, so the image holds nothing
# of it.
#
# Why not pip: Hermes's setup.py refuses wheel and sdist builds, and its pyproject.toml pins
# Pillow==13.0.0 beside a browser-harness that asks for pillow==12.3.0. Only uv reads the override
# that settles this ([tool.uv] override-dependencies), so pip cannot resolve it. `uv sync --frozen`
# installs exactly what uv.lock says, and Hermes editable.
FROM python:3.14-slim

# The uv Hermes pins for itself (its pm/lock.json).
ARG UV_VERSION=0.13.5

ENV PYTHONDONTWRITEBYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_NO_CACHE=1 \
    UV_PYTHON_DOWNLOADS=never

# Hermes's source is the build context `hermes`: test-with-hermes.sh fetches the pinned commit with
# git and hands the tree over, so the build itself reaches only PyPI.
COPY --from=hermes . /opt/hermes

# Behind a proxy that re-signs TLS, pass its CA as the build secret `ca` (test-with-hermes.sh does,
# from HERMES_TEST_CA); with no secret this is the image's own trust.
RUN --mount=type=secret,id=ca,required=false \
    if [ -s /run/secrets/ca ]; then export SSL_CERT_FILE=/run/secrets/ca PIP_CERT=/run/secrets/ca; fi && \
    pip install --no-cache-dir --disable-pip-version-check --root-user-action ignore "uv==${UV_VERSION}" && \
    cd /opt/hermes && \
    uv sync --frozen --python "$(command -v python)" && \
    uv pip install --python .venv/bin/python pytest

ENV PATH=/opt/hermes/.venv/bin:$PATH \
    HERMES_HOME=/tmp/hermes-home
RUN mkdir -p "$HERMES_HOME" && \
    python -c "import tools.skill_ledger, tools.skill_manager_tool, tools.skill_usage, agent.skill_utils"

WORKDIR /plugin
# -p no:cacheprovider: the plugin is mounted read-only. SHION_REQUIRE_HERMES: a Hermes that is not
# there fails these tests, where elsewhere it skips them.
ENV SHION_REQUIRE_HERMES=1
CMD ["python", "-m", "pytest", "-p", "no:cacheprovider", "-v", "-rs", "tests/test_reviews_hermes.py"]
