defmodule SymphonyElixirWeb.StaticAssets do
  @moduledoc false

  @dashboard_css_path Path.expand("../../priv/static/dashboard.css", __DIR__)
  @favicon_path Path.expand("../../priv/static/favicon.png", __DIR__)
  @phoenix_html_js_path Application.app_dir(:phoenix_html, "priv/static/phoenix_html.js")
  @phoenix_js_path Application.app_dir(:phoenix, "priv/static/phoenix.js")
  @phoenix_live_view_js_path Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.js")
  @dashboard_live_path Path.expand("live/dashboard_live.ex", __DIR__)
  @layouts_path Path.expand("components/layouts.ex", __DIR__)
  @presenter_path Path.expand("presenter.ex", __DIR__)
  @compiled_at System.system_time(:millisecond)

  @external_resource @dashboard_css_path
  @external_resource @favicon_path
  @external_resource @phoenix_html_js_path
  @external_resource @phoenix_js_path
  @external_resource @phoenix_live_view_js_path
  @external_resource @dashboard_live_path
  @external_resource @layouts_path
  @external_resource @presenter_path

  @dashboard_css File.read!(@dashboard_css_path)
  @dashboard_css_digest :crypto.hash(:sha256, @dashboard_css)
                        |> Base.encode16(case: :lower)
                        |> binary_part(0, 12)
  @favicon File.read!(@favicon_path)
  @favicon_digest :crypto.hash(:sha256, @favicon)
                  |> Base.encode16(case: :lower)
                  |> binary_part(0, 12)
  @phoenix_html_js File.read!(@phoenix_html_js_path)
  @phoenix_js File.read!(@phoenix_js_path)
  @phoenix_live_view_js File.read!(@phoenix_live_view_js_path)

  @assets %{
    "/dashboard.css" => {"text/css", @dashboard_css},
    "/favicon.png" => {"image/png", @favicon},
    "/dashboard-reload.js" => {"application/javascript", nil},
    "/vendor/phoenix_html/phoenix_html.js" => {"application/javascript", @phoenix_html_js},
    "/vendor/phoenix/phoenix.js" => {"application/javascript", @phoenix_js},
    "/vendor/phoenix_live_view/phoenix_live_view.js" => {"application/javascript", @phoenix_live_view_js}
  }

  @spec dashboard_css_url() :: String.t()
  def dashboard_css_url, do: "/dashboard.css?v=#{@dashboard_css_digest}"

  @spec favicon_url() :: String.t()
  def favicon_url, do: "/favicon.png?v=#{@favicon_digest}"

  @reload_page_paths [@dashboard_live_path, @layouts_path, @presenter_path]

  @spec fetch(String.t()) :: {:ok, String.t(), binary()} | :error
  def fetch("/dashboard.css") do
    {:ok, "text/css", fresh_file_body(@dashboard_css_path, @dashboard_css)}
  end

  def fetch("/dashboard-reload.js") do
    {:ok, "application/javascript", dashboard_reload_js()}
  end

  def fetch(path) when is_binary(path) do
    case Map.fetch(@assets, path) do
      {:ok, {content_type, body}} -> {:ok, content_type, body}
      :error -> :error
    end
  end

  @spec cache_control(String.t()) :: String.t()
  def cache_control(path) when path in ["/dashboard.css", "/dashboard-reload.js"] do
    "no-cache, no-store, must-revalidate"
  end

  def cache_control(_path), do: "public, max-age=31536000"

  @spec reload_version_payload() :: map()
  def reload_version_payload do
    %{
      server: Integer.to_string(@compiled_at),
      css: file_fingerprint([@dashboard_css_path]),
      page: file_fingerprint(@reload_page_paths)
    }
  end

  defp fresh_file_body(path, fallback) do
    case File.read(path) do
      {:ok, body} -> body
      {:error, _reason} -> fallback
    end
  end

  defp file_fingerprint(paths) do
    paths
    |> Enum.map(&file_signature/1)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp file_signature(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {path, mtime, size}
      {:error, reason} -> {path, reason}
    end
  end

  defp dashboard_reload_js do
    """
    (() => {
      const endpoint = "/api/v1/dev/reload-version";
      const themeKey = "symphony-theme";
      let current = null;

      function currentTheme() {
        return document.documentElement.dataset.theme === "dark" ? "dark" : "light";
      }

      function applyTheme(theme) {
        const next = theme === "dark" ? "dark" : "light";
        document.documentElement.dataset.theme = next;

        try {
          localStorage.setItem(themeKey, next);
        } catch (_error) {}

        document.querySelectorAll("[data-theme-toggle-label]").forEach((node) => {
          node.textContent = next === "dark" ? "Night" : "Day";
        });
      }

      function toggleTheme() {
        applyTheme(currentTheme() === "dark" ? "light" : "dark");
      }

      function updateCss(version) {
        const existing = document.querySelector('link[rel="stylesheet"][href^="/dashboard.css"]');
        if (!existing) return;

        const next = existing.cloneNode();
        next.href = "/dashboard.css?v=" + encodeURIComponent(version);
        next.onload = () => existing.remove();
        existing.parentNode.insertBefore(next, existing.nextSibling);
      }

      async function check() {
        try {
          const response = await fetch(endpoint, {cache: "no-store"});
          if (!response.ok) return;

          const next = await response.json();
          if (!current) {
            current = next;
            return;
          }

          if (next.server !== current.server || next.page !== current.page) {
            window.location.reload();
            return;
          }

          if (next.css !== current.css) {
            updateCss(next.css);
            current = next;
          }
        } catch (_error) {
          // A restart briefly drops the endpoint; the LiveView socket handles reconnecting.
        }
      }

      document.addEventListener("click", (event) => {
        if (event.target.closest("[data-theme-toggle]")) {
          toggleTheme();
        }
      });

      setInterval(check, 1200);
      applyTheme(currentTheme());
      check();
    })();
    """
  end
end
