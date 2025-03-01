defmodule EXLA.Client do
  @moduledoc """
  Functions for managing `EXLA.Client`.

  See `EXLA` module docs for a general introduction.
  """
  require Logger
  use GenServer
  @name __MODULE__

  @enforce_keys [:ref, :platform, :name, :device_count, :default_device_id]
  defstruct [:ref, :platform, :name, :device_count, :default_device_id]

  @doc """
  Fetches a client with the given `name` from configuration.
  """
  def fetch!(name) when is_atom(name) do
    # We could use the LockedCache but that is ETS based and the clients
    # are static enough that we can keep them on `persistent_term`.
    :persistent_term.get({__MODULE__, name}, nil) ||
      (
        clients = Application.fetch_env!(:exla, :clients)

        options =
          Keyword.get(clients, name) ||
            raise ArgumentError,
                  "could not find EXLA client named #{inspect(name)}, the clients specified " <>
                    "in your config files are: #{inspect(Keyword.keys(clients))}"

        GenServer.call(@name, {:client, name, options}, :infinity)
      )
  end

  @doc """
  Returns a map of supported platforms with device information.
  """
  def get_supported_platforms do
    EXLA.NIF.get_supported_platforms()
    |> unwrap!()
    |> Map.new(fn {k, v} ->
      k = k |> List.to_string() |> String.downcase(:ascii) |> String.to_atom()
      {k, v}
    end)
  end

  @doc """
  Sends `data_and_shapes` to device infeed.

  `data_and_shapes` must be a list of two element tuples where the
  first element is a binary or a flat list of binaries and the second
  element is a `EXLA.Shape`.

  > Note: XLA does not support tuple infeed shapes when running on
  > host. Passing one will simply block the operation indefinitely.
  > Instead, convert the tuple into multiple infeed operations.
  """
  def to_infeed(%EXLA.Client{ref: client}, device_id, data_and_shapes)
      when is_list(data_and_shapes) do
    data_and_shapes =
      Enum.map(data_and_shapes, fn
        {binary, %EXLA.Shape{ref: shape}} when is_binary(binary) -> {[binary], shape}
        {[binary | _] = data, %EXLA.Shape{ref: shape}} when is_binary(binary) -> {data, shape}
      end)

    EXLA.NIF.transfer_to_infeed(client, device_id, data_and_shapes) |> unwrap!()
  end

  @doc """
  Sends buffer from device outfeed to the given process tagged by `ref`.

  > Note: XLA does not support tuple outfeed shapes. Passing one will simply
  > block the operation indefinitely. Instead, convert the tuple into multiple
  > outfeed operations.
  """
  def from_outfeed(%EXLA.Client{ref: client}, device_id, shapes, pid, ref) when is_list(shapes) do
    shape_refs = Enum.map(shapes, fn %EXLA.Shape{ref: shape_ref} -> shape_ref end)
    EXLA.NIF.transfer_from_outfeed(client, device_id, shape_refs, pid, ref) |> unwrap!()
  end

  @doc """
  Copies buffer to device with given device ID.
  """
  def copy_buffer_to_device(%EXLA.Client{ref: client}, %EXLA.DeviceBuffer{ref: buffer}, device_id)
      when is_integer(device_id) do
    EXLA.NIF.copy_buffer_to_device(client, buffer, device_id) |> unwrap!()
  end

  ## Callbacks

  @doc false
  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    {:ok, :unused_state}
  end

  @impl true
  def handle_call({:client, name, options}, _from, state) do
    client = :persistent_term.get({__MODULE__, name}, nil) || build_client(name, options)
    :persistent_term.put({__MODULE__, name}, client)
    {:reply, client, state}
  end

  defp build_client(name, options) do
    platform = Keyword.get(options, :platform)
    default_device_id = Keyword.get(options, :default_device_id, 0)
    memory_fraction = Keyword.get(options, :memory_fraction, 0.9)

    preallocate = Keyword.get(options, :preallocate, true)
    preallocate_int = if preallocate, do: 1, else: 0

    platforms = Map.keys(EXLA.Client.get_supported_platforms())

    ref =
      case platform do
        nil ->
          Logger.debug("""
          No platform configuration specified, falling back to host platform
          Available platforms are: #{inspect(platforms)}
          """)

          EXLA.NIF.get_host_client()

        :host ->
          EXLA.NIF.get_host_client()

        :cuda ->
          EXLA.NIF.get_gpu_client(memory_fraction, preallocate_int)

        :rocm ->
          EXLA.NIF.get_gpu_client(memory_fraction, preallocate_int)

        :tpu ->
          EXLA.NIF.get_tpu_client()

        _ ->
          raise ArgumentError, "unknown EXLA platform: #{inspect(platform)}"
      end
      |> unwrap!()

    device_count = EXLA.NIF.get_device_count(ref) |> unwrap!()

    if default_device_id not in 0..(device_count - 1) do
      raise ArgumentError, ":default_device_id must be a number between 0 and #{device_count - 1}"
    end

    %EXLA.Client{
      ref: ref,
      platform: platform,
      name: name,
      device_count: device_count,
      default_device_id: default_device_id
    }
  end

  defp unwrap!(:ok), do: :ok
  defp unwrap!({:ok, ref}), do: ref
  defp unwrap!({:error, error}), do: raise(List.to_string(error))
end
