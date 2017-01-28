require 'ffi'

module RawMIDI
  module LibC
    extend FFI::Library
    ffi_lib FFI::Library::LIBC

    # Needed for some functions that expects the user frees memory after use
    attach_function :free, [:pointer], :void
  end

  module API
    extend FFI::Library

    ffi_lib 'libasound'

    enum :snd_ctl_mode, [:default, :nonblock, :async, :readonly]
    enum :snd_rawmidi_stream, [:output, :input]

    # snd_ctl
    class SndCtl < FFI::Struct
      layout :dl_handle, :pointer,      # void*
             :name, :pointer,           # char*
             :type, :pointer,
             :ops, :pointer,            # const snd_ctl_ops_t*
             :private_data, :pointer,   # void*
             :nonblock, :ulong,
             :poll_fd, :ulong,
             :async_handlers, :ulong
    end

    # snd_rawmidi_info
    class SndRawMIDIInfo < FFI::Struct
      layout :device, :uint,            # RO/WR (control): device number
             :subdevice, :uint,         # RO/WR (control): subdevice number
             :stream, :int,             # WR: stream
             :card, :int,               # R: card number
             :flags, :uint,             # SNDRV_RAWMIDI_INFO_XXXX
             :id, [:uchar, 64],         # ID (user selectable)
             :name, [:uchar, 80],       # name of device
             :subname, [:uchar, 32],    # name of active or selected subdevice
             :subdevices_count, :uint,
             :subdevices_avail, :uint,
             :reserved, [:uchar, 64]    # reserved for future use
    end

    # const char* snd_strerror(int error_number)
    attach_function :snd_strerror, [:int], :string

    # int snd_card_next(card&)
    attach_function :snd_card_next, [:pointer], :int
    # int snd_card_get_name(int card, char **name)
    attach_function :snd_card_get_name, [:int, :pointer], :int
    # int snd_card_get_longname(int card, char **name)
    attach_function :snd_card_get_longname, [:int, :pointer], :int

    # int snd_ctl_open(snd_ctl_t** ctl, const char* name, int mode)
    attach_function :snd_ctl_open, [:pointer, :pointer, :snd_ctl_mode], :int
    # int snd_ctl_close(snd_ctl_t* ctl)
    attach_function :snd_ctl_close, [:pointer], :int
    # int snd_ctl_rawmidi_next_device(snd_ctl_t* control, &device)
    attach_function :snd_ctl_rawmidi_next_device, [:pointer, :pointer], :int
    attach_function :snd_ctl_rawmidi_info, [:pointer, :pointer], :int

    # int snd_rawmidi_open(snd_rawmidi_t** input, snd_rawmidi_t output,
    attach_function :snd_rawmidi_open, [:pointer, :pointer, :string, :int], :int
    # int snd_rawmidi_close(snd_rawmidi_t* rawmidi)
    attach_function :snd_rawmidi_close, [:pointer], :int
    # int snd_rawmidi_write(snd_rawmidi_t* output, char* data, int datasize)
    attach_function :snd_rawmidi_write, [:pointer, :ulong, :size_t], :ssize_t
    # void snd_rawmidi_info_set_device(snd_rawmidi_info_t *obj, unsigned int val)
    attach_function :snd_rawmidi_info_set_device, [:pointer, :uint], :void
    # void snd_rawmidi_info_set_subdevice (snd_rawmidi_info_t *obj, unsigned int val)
    attach_function :snd_rawmidi_info_set_subdevice, [:pointer, :uint], :void
    # void snd_rawmidi_info_set_stream(snd_rawmidi_info_t *obj, snd_rawmidi_stream_t val)
    attach_function :snd_rawmidi_info_set_stream, [:pointer, :snd_rawmidi_stream], :void
    # unsigned int snd_rawmidi_info_get_subdevices_count(const snd_rawmidi_info_t *obj)
    attach_function :snd_rawmidi_info_get_subdevices_count, [:pointer], :uint
    # const char* snd_rawmidi_info_get_name(const snd_rawmidi_info_t *obj)
    attach_function :snd_rawmidi_info_get_name, [:pointer], :string

    def self.each_card_id
      return enum_for(__method__) unless block_given?

      card_p = FFI::MemoryPointer.new(:int).write_int(-1)

      loop do
        status = snd_card_next(card_p)
        raise Error, snd_strerror(status) if status < 0
        id = card_p.read_int

        break if id < 0
        yield id
      end
    end

    def self.each_device_id(card)
      return enum_for(__method__, card) unless block_given?

      with_card(card) do |ctl_p|
        device_p = FFI::MemoryPointer.new(:int).write_int(-1)

        loop do
          status = snd_ctl_rawmidi_next_device(ctl_p, device_p)
          if status < 0
            snd_ctl_close(ctl_p)
            raise Error, "cannot determine device number: #{snd_strerror(status)}"
          end

          device = device_p.read_int

          break if device < 0
          yield device
        end
      end
    end

    def self.with_card(card)
      return enum_for(__method__, card) unless block_given?

      ctl_pp = FFI::MemoryPointer.new(:pointer)
      status = snd_ctl_open(ctl_pp, "hw:#{card}", :readonly)
      if status < 0
        raise Error, "cannot open control for card #{card}: #{snd_strerror(status)}"
      end

      ctl_p = ctl_pp.read_pointer
      res = yield(ctl_p)

      snd_ctl_close(ctl_p)

      res
    end

    def self.card_get_name(id)
      name_pp = FFI::MemoryPointer.new(:pointer)
      status = snd_card_get_name(id, name_pp)
      raise Error, snd_strerror(status) if status < 0

      name_p = name_pp.read_pointer
      name = name_p.read_string
      LibC.free(name_p)

      name
    end

    def self.card_get_longname(id)
      name_pp = FFI::MemoryPointer.new(:pointer)
      status = snd_card_get_longname(id, name_pp)
      raise Error, snd_strerror(status) if status < 0

      name_p = name_pp.read_pointer
      name = name_p.read_string
      LibC.free(name_p)

      name
    end

    def self.subdevice_info(card, device, subdevice=0)
      with_card(card) do |ctl_p|
        info_p = FFI::MemoryPointer.new(:char, SndRawMIDIInfo.size, true)

        snd_rawmidi_info_set_device(info_p, device)
        snd_rawmidi_info_set_subdevice(info_p, subdevice)

        snd_rawmidi_info_set_stream(info_p, :input)
        status = snd_ctl_rawmidi_info(ctl_p, info_p)
        is_input = status >= 0

        snd_rawmidi_info_set_stream(info_p, :output)
        status = snd_ctl_rawmidi_info(ctl_p, info_p)
        is_output = status >= 0

        name = snd_rawmidi_info_get_name(info_p)

        {name: name, input: is_input, output: is_output}
      end
    end
  end
end
