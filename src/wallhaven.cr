require "http/client"
require "json"
require "uri"
require "./store"

# Wallhaven API client (https://wallhaven.cc/help/api).
#
# Covers the full search surface: query, category and purity bitmasks, sorting
# and order, toplist range, `atleast` minimum resolution, exact resolutions,
# aspect ratios, colour filter, seed and pagination. An API key unlocks the
# NSFW purity bit and larger result sets.
class Wallhaven
  BASE = "https://wallhaven.cc/api/v1"

  # Category bitmask: general / anime / people. "111" = all.
  CATEGORIES = {
    "General" => "100",
    "Anime"   => "010",
    "People"  => "001",
  }

  # Purity bitmask: sfw / sketchy / nsfw. "100" = SFW only.
  PURITY = {
    "SFW"     => "100",
    "Sketchy" => "010",
    "NSFW"    => "001",
  }

  SORTING = {
    "Date added" => "date_added",
    "Relevance"  => "relevance",
    "Random"     => "random",
    "Views"      => "views",
    "Favorites"  => "favorites",
    "Toplist"    => "toplist",
  }

  ORDER = {
    "Descending" => "desc",
    "Ascending"  => "asc",
  }

  TOP_RANGE = {
    "1 day"   => "1d",
    "3 days"  => "3d",
    "1 week"  => "1w",
    "1 month" => "1M",
    "3 months" => "3M",
    "6 months" => "6M",
    "1 year"   => "1y",
  }

  RATIOS = {
    "Any"       => "",
    "Landscape" => "landscape",
    "Portrait"  => "portrait",
    "16x9"      => "16x9",
    "16x10"     => "16x10",
    "21x9"      => "21x9",
    "9x16"      => "9x16",
    "3x2"       => "3x2",
    "4x3"       => "4x3",
  }

  # Common resolution presets for the `resolutions` parameter.
  RESOLUTIONS = [
    "", "1280x720", "1366x768", "1600x900", "1920x1080", "1920x1200",
    "2560x1080", "2560x1440", "3440x1440", "3840x1080", "3840x2160",
    "5120x1440", "7680x4320",
  ]

  # `atleast` presets (any resolution >= this).
  AT_LEAST = [
    "", "1280x720", "1920x1080", "2560x1440", "3840x2160",
  ]

  # A single search request.
  record Query,
    q : String = "",
    categories : String = "111",
    purity : String = "100",
    sorting : String = "date_added",
    order : String = "asc",
    top_range : String = "",
    at_least : String = "",
    resolutions : String = "",
    ratios : String = "",
    colors : String = "",
    page : Int32 = 1,
    seed : String = ""

  class Error < Exception
  end

  class Result
    property data : Array(Wallpaper)
    property page : Int32
    property last_page : Int32
    property total : Int32
    property seed : String?

    def initialize(@data, @page, @last_page, @total, @seed = nil)
    end
  end

  def initialize(@api_key : String? = nil)
    @client = HTTP::Client.new(URI.parse(BASE))
    @client.read_timeout = 30.seconds
    @client.connect_timeout = 10.seconds
  end

  def api_key=(key : String?)
    @api_key = key
  end

  def close
    @client.close
  end

  # Build the query string for a search (exposed for tests / the CLI `--dry-run`).
  def self.params(query : Query, api_key : String?) : URI::Params
    p = URI::Params.new
    p["q"] = query.q unless query.q.empty?
    p["categories"] = query.categories.empty? ? "111" : query.categories
    p["purity"] = query.purity.empty? ? "100" : query.purity
    p["sorting"] = query.sorting.empty? ? "date_added" : query.sorting
    p["order"] = query.order.empty? ? "asc" : query.order
    p["page"] = query.page.to_s
    p["topRange"] = query.top_range unless query.top_range.empty?
    p["atleast"] = query.at_least unless query.at_least.empty?
    p["resolutions"] = query.resolutions unless query.resolutions.empty?
    p["ratios"] = query.ratios unless query.ratios.empty?
    p["colors"] = query.colors.gsub("#", "") unless query.colors.empty?
    p["seed"] = query.seed unless query.seed.empty?
    p["apikey"] = api_key if (key = api_key) && !key.empty?
    p
  end

  def search(query : Query) : Result
    url = "#{BASE}/search?#{self.class.params(query, @api_key)}"
    body = get(url)
    json = JSON.parse(body)
    data = json["data"].as_a.map { |item| wallpaper_from(item) }
    meta = json["meta"]
    Result.new(
      data,
      meta["current_page"].as_i,
      meta["last_page"].as_i,
      meta["total"].as_i,
      meta["seed"]?.try(&.as_s?))
  rescue ex : JSON::ParseException | KeyError
    raise Error.new("unexpected wallhaven response: #{ex.message}")
  end

  # Fetch several consecutive pages and merge them (wallhaven caps a search at
  # ~24-48 results per page; a grid wants more than one page in a pass).
  def search_pages(query : Query, pages : Int32) : Result
    return search(query) if pages <= 1
    results = Array(Result).new(pages)
    pages.times do |i|
      q = query
      q = Query.new(q.q, q.categories, q.purity, q.sorting, q.order, q.top_range,
        q.at_least, q.resolutions, q.ratios, q.colors, query.page + i, q.seed)
      r = search(q)
      results << r
      break if r.page >= r.last_page
    end
    first = results.first
    merged = results.flat_map(&.data)
    Result.new(merged, first.page, results.last.last_page, first.total, first.seed)
  end

  # Look up a single wallpaper by id.
  def wallpaper(id : String) : Wallpaper?
    body = get("#{BASE}/w/#{id}#{@api_key.try { |k| k.empty? ? "" : "?apikey=#{k}" }}")
    JSON.parse(body)["data"]?.try { |d| wallpaper_from(d) }
  rescue Error
    nil
  end

  # Convert one API object into a `Wallpaper` row.
  def wallpaper_from(item : JSON::Any) : Wallpaper
    id = item["id"].as_s
    w = Wallpaper.new(id, "wallhaven")
    w.url = item["path"]?.try(&.as_s?)
    w.page_url = item["url"]?.try(&.as_s?)
    w.resolution = item["resolution"]?.try(&.as_s?)
    w.category = item["category"]?.try(&.as_s?)
    w.purity = item["purity"]?.try(&.as_s?)
    w.colors_json = item["colors"]?.try(&.to_json)
    w.meta_json = item.to_json
    w
  end

  private def get(url : String) : String
    response = @client.get(url)
    unless response.success?
      raise Error.new("wallhaven #{response.status_code}: #{response.body[0, 200]}?")
    end
    response.body
  rescue ex : IO::Error | Socket::Error
    raise Error.new("network error: #{ex.message}")
  end
end
