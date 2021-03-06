#' Use OTP Geo-coder to find a location
#'
#' Geo-coding converts a named place, such as a street name into a lng/lat pair.
#'
#' @param otpcon OTP connection object produced by otp_connect()
#' @param surface A suface list from otp_make_surface()
#' @param pointsset character, name of pointset
#' @return Returns a data.frame of travel times
#' @examples
#' \dontrun{
#' times <- otp_surface(otpcon, c(-1.17502, 50.64590), "lsoa", path_data)
#' }
#' @details THis function requires the analysis and pointset features to be
#' enabled during `otp_setup()`. Thus it will only work with OTP 1.x. For more
#' detail see the analyst vignette.
#'
#' @export
otp_surface <- function(otpcon = NULL,
                        surface = NULL,
                        pointsset = NULL) {
  # Check for OTP2
  if (!is.null(otpcon$otp_version)) {
    if (otpcon$otp_version >= 2) {
      stop("Surface is not supported by OTP v2.X")
    }
  }

  surfaceUrl <- make_url(otpcon, type = "surfaces")
  surfaceUrl <- paste0(surfaceUrl,
                       "/",
                       surface$id,
                       "/indicator?targets=",
                       pointsset,
                       "&detail=true")

  # convert response content into text
  h <- curl::new_handle()
  #curl::handle_setopt(h, post = TRUE)
  text <- curl::curl_fetch_memory(surfaceUrl, handle = h)
  if(text$status_code == 200){
    text <- rawToChar(text$content)
  } else {
    stop("Error getting surface code: ",text$status_code)
  }

  asjson <- rjson::fromJSON(text)

  # from otpr
  response <- list()
  for (i in 1:length(asjson[["data"]])) {
    name <- names(asjson$data[i])
    asjson[["data"]][[i]]["cumsums"] <-
      list(cumsum(asjson[["data"]][[i]][["sums"]]))
    asjson[["data"]][[i]]["minutes"] <-
      list(seq(1, length(asjson[["data"]][[i]][2]$counts)))
    df <- data.frame(Reduce(rbind, asjson$data[i]))
    df <- df[, c("minutes", "counts", "sums", "cumsums")]
    #assign(paste0("s", surfaceId, "_", name), df)
    #response[[name]] <-
    #  assign(paste0("s", surfaceId, "_", name), df)
  }

  times <- asjson$times
  times[times == 2147483647] <- NA
  response$times <- times


  return(response)
}


#' Make a Surface
#'
#' Requires OTP 1.x and the analyst
#'
#' @param otpcon OTP connection object produced by otp_connect()
#' @param fromPlace Numeric vector, Longitude/Latitude pair, e.g.
#'   `c(-0.134649,51.529258)`, or 2 column matrix of Longitude/Latitude pairs,
#'   or sf data frame of POINTS with CRS 4326
#' @param date_time POSIXct, a date and time, defaults to current date and time
#' @param maxWalkDistance Numeric passed to OTP in metres
#' @param arriveBy Logical, Whether the trip should depart or arrive at the
#'   specified date and time, default FALSE
#' @param timezone Character, what timezone to use, see as.POSIXct, default is
#'   local timezone
#' @family analyst
#' @return Returns a list with information about the surface created
#' @examples
#' \dontrun{
#' surface <- otp_make_surface(otpcon, c(-1.17502, 50.64590))
#' }
#' @details THis function requires the analysis and pointset features to be
#' enabled during `otp_setup()`. Thus it will only work with OTP 1.x. For more
#' detail see the analyst vignette.
#'
#' @export
otp_make_surface <- function(otpcon = NULL,
                        fromPlace = c(-1.17502,50.64590),
                        mode = "CAR",
                        date_time = Sys.time(),
                        maxWalkDistance = 1000,
                        arriveBy = FALSE,
                        timezone = otpcon$timezone) {
  # Check for OTP2
  if (!is.null(otpcon$otp_version)) {
    if (otpcon$otp_version >= 2) {
      stop("Surface is not supported by OTP v2.X")
    }
  }

  if (is.null(timezone)) {
    warning("otpcon is missing the timezone variaible, assuming local timezone")
    timezone <- Sys.timezone()
  }

  # Validate Inputs
  date <- format(date_time, "%m-%d-%Y", tz = timezone)
  time <- tolower(format(date_time, "%I:%M%p", tz = timezone))
  checkmate::assert_class(otpcon, "otpconnect")
  mode <- toupper(mode)
  checkmate::assert_subset(mode,
                           choices = c(
                             "TRANSIT", "WALK", "BICYCLE",
                             "CAR", "BUS", "RAIL"
                           ),
                           empty.ok = FALSE
  )
  mode <- paste(mode, collapse = ",")
  checkmate::assert_logical(arriveBy)
  arriveBy <- tolower(arriveBy)

  fromPlace <- otp_clean_input(fromPlace, "fromPlace")
  fromPlace <- as.numeric(fromPlace)
  fromPlace <- format(fromPlace, scientific = FALSE, digits = 9, trim = TRUE)
  fromPlace <- paste(fromPlace, collapse = ",")
  # Make POST Request to build surface

  surfaceUrl <- make_url(otpcon, type = "surfaces")
  querylist <- list(
    batch = "true",
    fromPlace = fromPlace,
    #date = date,
    #time = time,
    mode = mode,
    maxWalkDistance = maxWalkDistance,
    arriveBy = arriveBy
  )

  # convert response content into text
  url <- build_url(surfaceUrl, querylist)
  h <- curl::new_handle()
  curl::handle_setopt(h, post = TRUE)
  text <- curl::curl_fetch_memory(url, handle = h)
  if(text$status_code == 200){
    text <- rawToChar(text$content)
  } else {
    stop("Error making surface code: ",text$status_code)
  }
  asjson <- rjson::fromJSON(text)

  return(asjson)

}

#'  Create a pointset
#'
#' @param points sf data frame of POINTS with CRS 4326
#' @param name Character, name for pointset
#' @param dir A character string, path to a directory containing the necessary
#'   files, see details
#'
#' @family routing
#' @return
#' Returns a data.frame of SF POINTS or Coordinates of all
#'     the locations that match `query`
#' @examples
#' \dontrun{
#' locations <- otp_geocode(otpcon, "High Street")
#' }
#' @details
#' OTP will return a maximum of 10 results
#'
#' @export
otp_pointset <- function(points = NULL,
                        name = NULL,
                        dir = NULL) {

  if(!"sf" %in% class(points)){
    stop("points is not an sf object")
  }

  if(any(sf::st_geometry_type(points) != "POINT")){
    stop("points is not make up of points")
  }

  if(!sf::st_is_longlat(points)){
    stop("points is not in lng/lat format use sf::st_transform(points, 4326)")
  }

  coords <- as.data.frame(sf::st_coordinates(points))
  names(coords) <- c("lon","lat")
  coords <- coords[,2:1]
  points <- sf::st_drop_geometry(points)
  points <- cbind(coords, points)
  cls <- vapply(points, class, FUN.VALUE = "character", USE.NAMES = FALSE)
  points <- points[,cls %in% c("integer","numeric")]


  if(!dir.exists(file.path(dir,"pointsets"))){
    dir.create(file.path(dir,"pointsets"))
  }

  utils::write.csv(points,
            file = file.path(dir,"pointsets",paste0(name,".csv")),
            row.names = FALSE,
            quote = FALSE)

  return(NULL)
}
