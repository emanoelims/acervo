defmodule AcervoWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  Application-owned function components built with Phoenix.Component, Tailwind
  utilities, and the studio design tokens. Buttons, form controls,
  validation, notices, and popovers share the same palette and interaction rules.
  No external component framework is required.

  """
  use Phoenix.Component
  use Gettext, backend: AcervoWeb.Gettext

  alias Phoenix.HTML.Form
  alias Phoenix.HTML.FormField
  alias Phoenix.LiveView.JS

  @doc """
  Renders a non-modal popover anchored to its trigger with Floating UI.

  The browser owns disclosure state and placement, while LiveView continues
  updating the panel content. Popovers share entrance motion, outside-click
  dismissal, Escape dismissal with focus restoration, and exclusive opening.
  Supply unique IDs and an accessible label; use the trigger slot for its icon.
  Set `menu` for navigation popups containing `dropdown_item/1` rows; these add
  arrow-key navigation, Home/End, activation, and focus restoration on Escape.

  ## Examples

      <.popover id="more" label="More" menu trigger_class="head-button" panel_class="dropdown-menu">
        <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
        <.dropdown_item icon="lucide-pen-line" label="Rename" phx-click="rename" />
      </.popover>
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :title, :string, default: nil
  attr :trigger_id, :string, default: nil
  attr :trigger_class, :any, default: "icon-button"
  attr :class, :any, default: nil
  attr :panel_class, :any, default: nil
  attr :placement, :string, default: "bottom-end"
  attr :offset, :integer, default: 8
  attr :menu, :boolean, default: false
  slot :trigger, required: true
  slot :inner_block, required: true

  def popover(assigns) do
    assigns =
      assign(assigns,
        trigger_id: assigns.trigger_id || "#{assigns.id}-trigger",
        title: assigns.title || assigns.label
      )

    ~H"""
    <details
      id={@id}
      class={["popover", @class]}
      data-popover
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary
        id={@trigger_id}
        class={@trigger_class}
        aria-label={@label}
        title={@title}
        aria-haspopup={if @menu, do: "menu", else: "dialog"}
        aria-controls={"#{@id}-panel"}
        aria-expanded="false"
        phx-mounted={JS.ignore_attributes("aria-expanded")}
      >
        {render_slot(@trigger)}
      </summary>
      <span
        id={"#{@id}-positioner"}
        phx-hook="Floating"
        phx-update="ignore"
        data-panel={"#{@id}-panel"}
        data-placement={@placement}
        data-offset={@offset}
        hidden
      ></span>
      <div
        id={"#{@id}-panel"}
        class={["floating-panel popover-panel", @panel_class]}
        role={if @menu, do: "menu", else: "dialog"}
        aria-label={@label}
        phx-mounted={JS.ignore_attributes(["style", "data-placement", "data-positioned"])}
      >
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  @doc """
  Renders an icon and label row in a `popover/1` with `menu`. It navigates
  with `navigate` or `href`; without either it is a button, for actions.

  ## Examples

      <.dropdown_item icon="lucide-keyboard" label="Shortcuts" navigate={~p"/guide"} />
      <.dropdown_item id="rename" icon="lucide-pen-line" label="Rename" phx-click="rename" />
      <.dropdown_item icon="lucide-trash-2" label="Delete" danger phx-click="delete" />
  """
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :navigate, :string, default: nil
  attr :href, :any, default: nil
  attr :method, :string, default: "get"
  attr :current, :boolean, default: false
  attr :danger, :boolean, default: false
  attr :rest, :global

  def dropdown_item(%{navigate: nil, href: nil} = assigns) do
    ~H"""
    <button
      type="button"
      role="menuitem"
      tabindex="-1"
      class={["dropdown-item", @danger && "dropdown-item-danger"]}
      {@rest}
    >
      <.icon name={@icon} class="size-4" />
      <span class="dropdown-item-label">{@label}</span>
    </button>
    """
  end

  def dropdown_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      href={@href}
      method={@method}
      role="menuitem"
      tabindex="-1"
      class={["dropdown-item", @danger && "dropdown-item-danger"]}
      aria-current={@current && "page"}
      {@rest}
    >
      <.icon name={@icon} class="size-4" />
      <span class="dropdown-item-label">{@label}</span>
      <.icon :if={@current} name="lucide-thin-check" class="size-3.5" />
    </.link>
    """
  end

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="flash-stack"
      {@rest}
    >
      <div class={[
        "flash-message w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "flash-info",
        @kind == :error && "flash-error"
      ]}>
        <.icon :if={@kind == :info} name="lucide-thin-info" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="lucide-thin-circle-alert" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="icon-button self-start" aria-label={gettext("Close")}>
          <.icon name="lucide-thin-x" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled form type)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "action action-primary", nil => "action"}

    assigns =
      assign_new(assigns, :class, fn ->
        [Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number
               search select tel text textarea time url week hidden range)

  attr :field, FormField, doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global, include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns = field_state(assigns)

    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="form-field">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="field-check-label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            aria-invalid={@invalid? && "true"}
            aria-describedby={@described_by}
            class={@class || "field-check"}
            {@rest}
          />{@label}
        </span>
      </label>
      <div :if={@errors != []} id={@error_id} class="field-errors">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    assigns = field_state(assigns)

    ~H"""
    <div class="form-field">
      <label :if={@label} for={@id} id={@id && "#{@id}-label"} class="field-label">{@label}</label>
      <div class="field-select-control">
        <select
          id={@id}
          name={@name}
          class={[@class || "field", @errors != [] && (@error_class || "field-invalid")]}
          multiple={@multiple}
          aria-invalid={@invalid? && "true"}
          aria-describedby={@described_by}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
        <div
          :if={@id && !@multiple}
          id={"#{@id}-picker"}
          phx-hook="Select"
          phx-update="ignore"
          data-native-select={@id}
          class="field-select-picker"
        >
        </div>
      </div>
      <div :if={@errors != []} id={@error_id} class="field-errors">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    assigns = field_state(assigns)

    ~H"""
    <div class="form-field">
      <label for={@id}>
        <span :if={@label} class="field-label">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          aria-invalid={@invalid? && "true"}
          aria-describedby={@described_by}
          class={[
            @class || "field textarea",
            @errors != [] && (@error_class || "field-invalid")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <div :if={@errors != []} id={@error_id} class="field-errors">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, etc. are handled here...
  def input(assigns) do
    assigns = field_state(assigns)

    ~H"""
    <div class="form-field">
      <label for={@id}>
        <span :if={@label} class="field-label">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          aria-invalid={@invalid? && "true"}
          aria-describedby={@described_by}
          class={[
            @class || "field",
            @errors != [] && (@error_class || "field-invalid")
          ]}
          {@rest}
        />
      </label>
      <div :if={@errors != []} id={@error_id} class="field-errors">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  defp field_state(assigns) do
    error_id = if assigns.id && assigns.errors != [], do: "#{assigns.id}-errors"

    described_by =
      [assigns.rest[:"aria-describedby"], error_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    assign(assigns,
      invalid?: assigns.errors != [],
      error_id: error_id,
      described_by: if(described_by == "", do: nil, else: described_by),
      rest: Map.delete(assigns.rest, :"aria-describedby")
    )
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="field-error">
      <.icon name="lucide-thin-info" class="size-4 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders the Acervo brand mark, a bundled Heroicon, or a Lucide icon.

  The `lucide-` prefix selects the vendored Lucide icons.
  Their SVGs and ISC license are kept in `assets/vendor/lucide` and bundled
  into app.css, using the same mask approach as Heroicons.

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "acervo-mark"} = assigns) do
    ~H"""
    <svg class={["acervo-mark", @class]} viewBox="0 0 32 32" aria-hidden="true">
      <rect
        x="9"
        y="5"
        width="18"
        height="18"
        rx="5"
        fill="none"
        stroke="currentColor"
        stroke-width="2.4"
        opacity=".45"
      />
      <rect x="5" y="9" width="18" height="18" rx="5" fill="currentColor" />
    </svg>
    """
  end

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  def icon(%{name: "lucide-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300", "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(AcervoWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(AcervoWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
