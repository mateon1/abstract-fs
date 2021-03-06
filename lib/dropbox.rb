require 'dropbox_api'

require_relative 'filesys'

module Dropbox
  @@dbx_client = nil

  module_function

  extend CloudFileSysBase

  def filesys_type
    "DBX:".black.on_light_cyan
  end

  def client
    @@dbx_client ||= DropboxApi::Client.new(DROPBOX_TOKEN)
  end

  def account
    client.get_current_account.to_hash
  end

  def metadata_compat(orig)
    return nil if orig.nil?
    orig = orig.to_hash if orig.class != Hash
    orig["sharing_info"] = {} if orig["sharing_info"].nil?
    mime = MIME::Types.type_for(orig["path_display"] || "")
    img_ext = [".png", ".jpeg", ".jpg", ".tif", ".tiff", ".gif", ".bmp"]
    has_thumb = ((orig["size"] || 0) < 20 * 2**20 &&
                 img_ext.include?(File.extname(orig["name"]).downcase))
    # XXX: What to use for root?
    # XXX: Creation time does not exist!
    meta = {
      "name" => orig["name"],
      # in v1, used to be human-readable size ("2.3 MB", "225.4KB", "0 bytes")
      "size" => orig["size"],
      "bytes" => orig["size"],
      "path" => orig["path_display"],
      "is_dir" => orig[".tag"] == "folder",
      "is_deleted" => orig[".tag"] == "deleted",
      "rev" => orig["rev"],
      "read_only" => orig["sharing_info"]["read_only"],
      "parent_shared_folder_id" => orig["sharing_info"]["parent_shared_folder_id"],
      "modifier" => orig["sharing_info"]["modified_by"],
      "mime_type" => (mime && mime.first ? mime.first.simplified : ""),
      "thumb_exists" => has_thumb,
      "hash" => orig["content_hash"],
      "modified" => orig["server_modified"],
      "client_mtime" => orig["client_modified"],
      "created" => "1970-01-01T00:00",
      "client_ctime" => "1970-01-01T00:00",
      # icon, root don't exist
      # photo_info, video_info, shared_folder - complex replacements
    }
    meta["contents"] = []
    if meta["is_dir"]
      result = list_folder(meta["path"])
      result.entries.each { |res| meta["contents"] << res.to_hash["path_display"] }
    end
    meta
  end

  def with_retry(&block)
    tries ||= DROPBOX_NO_OF_RETRIES
    yield
  # Using full names for the errors, as otherwise we get weird NameErrors
  rescue DropboxApi::Errors::TooManyRequestsError, DropboxApi::Errors::TooManyWriteOperationsError, DropboxApi::Errors::RateLimitError, DropboxApi::Errors::HTTPError
    sleep(DROPBOX_RETRY_DELAY + DROPBOX_NO_OF_RETRIES - tries)
    retry unless (tries -= 1).zero?
  rescue StandardError => ex
    error "Retry failed: #{ex.class.name}: #{ex.message}"
    raise ex
  end

  def download(dropbox_path, local_path)
    dropbox_path = normalize_path(dropbox_path)
    log_download(dropbox_path, local_path)
    contents = ""
    file = with_retry do
      contents = ""
      client.download dropbox_path do |chunk|
        contents << chunk
      end
    end
    metadata = file.to_hash
    FileUtils.mkdir_p(File.dirname(local_path))
    File.open(local_path, 'w') {|f| f.write(contents) }
    raise "File size mismatch" unless metadata['size'] == File.size(local_path)
    metadata_compat(metadata) # small change in API, we have confirmation here also that size match!
  rescue Exception => ex
    error "Download failed: %s." % ex.message
    nil
  end

  def upload(local_path, dropbox_path)
    # NOTE: It might be a good idea to implement a proper upload queue
    dropbox_path = normalize_path(dropbox_path)
    log_upload(local_path, dropbox_path)
    commit = DropboxApi::Metadata::CommitInfo.new(
      "path" => dropbox_path,
      "mode" => :add # NOTE: Will not overwrite existing file if exists
    )
    cursor = nil
    File.open(local_path) do |f|
      chunk = f.read(DROPBOX_UL_CHUNK_SIZE)
      cursor = with_retry { client.upload_session_start(chunk) }
      # HACK: We have to keep the offset ourselves, as the lib doesn't in 1.3.2
      offset = chunk.bytesize
      while chunk = f.read(DROPBOX_UL_CHUNK_SIZE)
        with_retry do
          cursor.instance_variable_set(:@offset, offset)
          client.upload_session_append_v2(cursor, chunk)
          offset += chunk.bytesize
        end
      end
      cursor.instance_variable_set(:@offset, offset)
    end
    with_retry { metadata_compat(client.upload_session_finish(cursor, commit)) }
  rescue Exception => ex
    error "Upload failed: %s." % ex.message
    nil
  end

  def normalize_path(path)
    path = path.join("/") if path.is_a? Array
    path = "/" + path if path[0] != '/'
    path
  end

  def find(dropbox_path)
    dropbox_path = normalize_path(dropbox_path)
    meta = with_retry do
      client.get_metadata(dropbox_path)
    end
    metadata_compat(meta)
  rescue Exception
    nil
  end

  def cp(dropbox_src_path, dropbox_dst_path, overwrite = true)
    dropbox_src_path = normalize_path(dropbox_src_path)
    dropbox_dst_path = normalize_path(dropbox_dst_path)
    rm(dropbox_dst_path, false) if overwrite
    log_cp(dropbox_src_path, dropbox_dst_path)
    meta = with_retry do
      client.copy(dropbox_src_path, dropbox_dst_path)
    end
    metadata_compat(meta)
  rescue Exception => ex
    error "Copy failed: %s" % ex.message
    nil
  end

  def mv(dropbox_src_path, dropbox_dst_path, overwrite = true)
    dropbox_src_path = normalize_path(dropbox_src_path)
    dropbox_dst_path = normalize_path(dropbox_dst_path)
    rm(dropbox_dst_path, false) if overwrite
    log_mv(dropbox_src_path, dropbox_dst_path)
    meta = with_retry do
      client.move(dropbox_src_path, dropbox_dst_path)
    end
    metadata_compat(meta)
  rescue Exception => ex
    error "Move failed: %s." % ex.message
    nil
  end

  def rm(dropbox_path, notify_on_missing = false)
    dropbox_path = normalize_path(dropbox_path)
    log_rm(dropbox_path) unless notify_on_missing
    meta = with_retry do
      client.delete(dropbox_path)
    end
    meta = metadata_compat(meta)
    meta["is_deleted"] = true # tag is not set to deleted when returned here
    meta
  rescue Exception => ex
    error "Rm failed: #{ex.class.name}: #{ex.message}"
    nil
  end

  # Direct link
  def dl(dropbox_path)
    with_retry do
      { "url" => client.get_temporary_link(dropbox_path).link }
    end
  rescue Exception => ex
    error "URL failed: %s." % ex.message
    nil
  end

  # Thumbnail of the image
  # FIXME
  def thb(dropbox_path, size)
    with_retry do
      client.get_thumbnail(dropbox_path, "size" => size)
    end
  rescue Exception => ex
    error "Thumbnail failed: %s." % ex.message
    nil
  end

  def mkdir(dropbox_path)
    meta = with_retry do
      client.create_folder(dropbox_path)
    end
    metadata_compat(meta)
  rescue Exception => ex
    error "Make dir failed: %s." % ex.message
    nil
  end
end
