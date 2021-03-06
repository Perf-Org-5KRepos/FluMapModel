#' getHumanReadableModelIdFromModel: return human readable verion of model from query
#'
#' @param model INLA model object that will generatie id from
#'
#' @return Unique String representing model in human readable format
#' @export
#'
getHumanReadableModelIdFromModel <- function(model, latent = FALSE) {
  return (getHumanReadableModelIdFromQuery(getModelQueryObjectFromModel(model, latent)))
}

#' getHumanReadableModelIdFromQuery: return human readable verion of model from query
#'
#' @param query query object container the observed and the model_type attributes
#'
#' @return Unique String representing model in human readable format
#' @export
#'
getHumanReadableModelIdFromQuery <- function(query) {
  props <- getModelQueryObjectFromQuery(query)
  result <- tolower(sprintf("%s-%s-%s-%s",
                            paste(props$model_type,collapse = "."),
                            paste(props$pathogen, collapse = "."),
                            paste(props$observed, collapse = "."),
                            paste(props$spatial_domain, collapse = ".")))  # paste(paste()) would be easier to maintain, but I'm leaving this for now
  return(result)
}

#' getModelQueryObjectFromModel: return query object from a model.
#' This is the object we use to generate our unique ids.
#'
#' @param model = Model object to get query object for
#' @param model_type = Model Type string: 'inla_observed' (default) or 'inla_latent'
#' @param latent = Bool determing if we are saving a latent model or a smooth model
#' @import logging
#'
#' @return An object containing the observed and the model_type fields
#' @export
#'
getModelQueryObjectFromModel<- function(model, latent = FALSE) {

  result <- newEmptyObject()
  if (latent) {
    result$model_type <- jsonlite::unbox('inla_latent')
    validColumnNames <- sort(colnames(model$modelDefinition$latentFieldData))
    
  } else {
    result$model_type <- jsonlite::unbox('inla_observed')
    validColumnNames <- sort(colnames(model$modelDefinition$observedData))
  }
    
  validIdx <-  !( validColumnNames %in% c('catchment','n','pathogen','positive') |
                  grepl('row',validColumnNames, ignore.case = TRUE) ) 
  
  validColumnNames <- validColumnNames[validIdx]
  
  result$observed <- validColumnNames
    
  
  # grab the pathogen from the where clause
  if ("WHERE" %in% names(model$modelDefinition$queryList) && 
      "COLUMN" %in% names(model$modelDefinition$queryList$WHERE) &&
      model$modelDefinition$queryList$WHERE$COLUMN == "pathogen" && 
      "IN" %in% names(model$modelDefinition$queryList$WHERE)
      )
  {
    logdebug("Pathogen from Query Src:", str(model$modelDefinition$queryList$WHERE$IN))
    result$pathogen <- model$modelDefinition$queryList$WHERE$IN
  } else {
    result$pathogen <- "all"
  }
  
  if ( !is.null(model$modelDefinition$spatial_domain)) {
    # grab spatial_domain from modelDefinition
    result$spatial_domain <- jsonlite::unbox(model$modelDefinition$spatial_domain)
  }

  logdebug("Result: ", result)
  return(result)
}
#' getModelQueryObjectFromQuery: Reformate a query object to ensure it is in proper order
#' before generating id.
#'
#' @param query query object container the observed and the model_type attributes
#'
#' @import logging
#'
#' @return An object containing the observed and the model_type fields
#' @export
#'
getModelQueryObjectFromQuery <- function(query) {
  basicConfig()
  setLevel("FINEST")

  logdebug("getModelQueryObjectFromQuery Src:", str(query))
  logdebug("$observed", attr(query, "observed"))
  result <- newEmptyObject()
  result$observed <- sort(query$observed)
  result$model_type <- query$model_type
  result$pathogen <- query$pathogen
  result$spatial_domain <- query$spatial_domain
  
  logdebug("getModelQueryObjectFromQuery result:", str(result))
  return(result)
}

#' getModelIdFromModel: function to get model id from a model objejct
#'
#' @param model INLA object
#' @param model_type String of model type
#' @param latent bool for if is latent model
#'
#' @export
#'
getModelIdFromModel <- function(mode, model_type = 'inla', latent = FALSE) {
  return(getModelIdFromQuery(getModelQueryObjectFromModel(model, model_type, latent)))
}

#' getModelIdFromQuery: function to save models and register them in modelDB.csv
#'
#' @param query query object container the observed and the model_type attributes
#'
#' @import digest
#' @import logging
#' @importFrom jsonlite toJSON
#' 
#' @export
#'
getModelIdFromQuery <- function(query) {
  basicConfig()
  setLevel("FINEST")

  #props <- getModelQueryObjectFromQuery(query)
  modelId <- as.character(jsonlite::toJSON(query))
  logdebug("Model ID JSON:", jsonlite::toJSON(query))
  modelId <- digest::digest(modelId, serialize=FALSE)
  logdebug("Model ID Hash:", modelId)
  return(modelId)
}

#' saveModel: function to save models and register them in modelDB.csv
#'
#' @param model INLA object
#'
#' @export
#'
saveModel <- function(model, modelStoreDir =  Sys.getenv('MODEL_STORE', '/home/rstudio/seattle_flu/test_model_store'), storeRDS = TRUE) {
  basicConfig()
  setLevel("FINEST")
  ts <- Sys.time()
  attr(ts, "tzone") <- 'UTC'
  ts <- paste0(as.character(ts), 'Z')
  
  # we always dump to our directory. We then use the python upload script to post
  # trained models to production
  modelDBfilename <- paste(modelStoreDir, '/', 'modelDB.tsv', sep = '')

  #ensure our model store directory exists
  dir.create(modelStoreDir, showWarnings = FALSE)

  # If we have a latent_field type, use that as base model and write out that csv
  if (model$modelDefinition$type == 'latent_field') {
    modelQuery <- getModelQueryObjectFromModel(model, latent = TRUE)
    modelId <- getModelIdFromQuery(modelQuery)
    name <- getHumanReadableModelIdFromModel(model, latent = TRUE)
    
    filename <-modelId
    rdsFilename <- if (storeRDS){ paste(modelStoreDir, '/', filename, '.RDS', sep = '')} else {''}
    
    newRow <- data.frame(
      filename = filename,
      name = name,
      queryJSON = as.character(jsonlite::toJSON(modelQuery)),
      type = 'inla_latent',
      created = ts,
      rds = rdsFilename
    )
    newRow$latent <- TRUE
    
    loginfo("Saving latent model")

    write.csv(
      model$latentField,
      paste(modelStoreDir, '/', filename, '.csv', sep = ''),
      row.names = FALSE,
      quote = FALSE
    )

    # write to our model db file
    write.table(
      newRow, file = modelDBfilename, sep = '\t', row.names = FALSE, col.names = !file.exists(modelDBfilename),
      quote = FALSE, append = file.exists(modelDBfilename)
    )
  }
  
  # all models output smooth
  loginfo("Saving smooth model")
  modelQuery <- getModelQueryObjectFromModel(model, latent = FALSE)
  modelId <- getModelIdFromQuery(modelQuery)
  name <- getHumanReadableModelIdFromModel(model, latent = FALSE)
  
  filename <-modelId
  
  # We store rds with smooth model name and we then can load that from either latent or smooth later id needed
  # This is only used when Store RDS is True
  if (storeRDS & !exists('rdsFilename')){ rdsFilename <- paste(modelStoreDir, '/', filename, '.RDS', sep = '')}
  
  newRow <- data.frame(
    filename = filename,
    name = name,
    queryJSON = as.character(jsonlite::toJSON(modelQuery)),
    type = 'inla_observed',
    created = ts,
    rds = rdsFilename,
    latent = FALSE
  )
  
  loginfo("Saving observed model")
  
  write.csv(
    model$modeledData,
    paste(modelStoreDir, '/', filename, '.csv', sep = ''),
    row.names = FALSE,
    quote = FALSE
  )
  write.table(
    newRow, file = modelDBfilename, sep = '\t', row.names = FALSE, col.names = !file.exists(modelDBfilename),
    quote = FALSE, append = file.exists(modelDBfilename)
  )
  
  if (storeRDS) {
    loginfo("Saving RDS")
    outfile <- xzfile(rdsFilename, 'wb', compress=9, encoding = 'utf8')
    saveRDS(model,file = outfile)
    close(outfile)
  }
}



