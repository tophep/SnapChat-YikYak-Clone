var express = require('express');
var path = require('path');
var multer  = require('multer');
var fs = require('fs');
// var dbController = require('db_controller');
var router = express.Router();


// Initialize Multer request parser
var formParser = multer({ 
        dest: './temp_uploads/', 
        inMemory: false,
        includeEmptyFields: false,
        putSingleFilesInArray: true, 
        rename: function (fieldname, filename) {
        	//non alpha-numeric characters replaced with a dash
            return filename.replace(/\W+/g, '-').toLowerCase() + "-" + Date.now();
        },
        onParseStart: function () {
            console.log('New Multipart Form Request:', new Date());
        }
});

var removeFiles = function(req){
	var files = req.files;
    for (key in files) {
    	var fileArray = files[key];
        for (index in fileArray){
        	var file = fileArray[index];
            fs.unlink(file.path, function(err){
                if (err) {
                	if (err["code"] != 'ENOENT') {
                		console.log("Failed to delete", file.path);
                		console.log("With Error:", err);	
                	}
                }
            });
        }
    }    
};

var authenticateRequest = function(req, res, next) {
	if (req.path == "/login" || dbController.validateUser(req.body["username"], req.body["access_token"])) {
		next();
	}
	else {
		// send error code and message
		removeFiles(req);
	}
};


var processUpload = function(req, res) {
	console.log("file uploaded");
    console.log("\n");
    // The request body contains the JSON data
    console.log(req.body);
    console.log("\n");
    // req.files is JSON structured as {"file_name":[array of files]}
    for (file in req.files) {
        console.log(file);
        console.log(req.files[file][0]);
    }

    res.sendStatus(200);
    // removeFiles(req);
};


// If a valid request comes through but doesn't hit one of the above routes
var reapRequest = function(req, res, next) {
	removeFiles(req);
    next();
};


router.use(formParser);
router.post("/upload", processUpload);
router.use(reapRequest);

module.exports = router;

